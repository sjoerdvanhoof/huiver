#!/usr/bin/env python
"""Check the multilingual decode loop against chatterbox's own, in torch.

    python verify_mtl.py               # the whole harness, ~2 minutes on CPU
    python verify_mtl.py --tokens 8    # shorter
    python verify_mtl.py --only sampler

This runs *before* anything is converted, and that ordering is the point.
Conversion is the step most likely to be quietly wrong, so the thing it is
measured against has to be known-good first — and "known-good" means a second
implementation of the loop agreeing with the original, not a single
implementation that produces plausible audio.

Four levels, from the one that localises a fault best to the one that matters:

  1. the prompt embeddings, where CFG zeroing and the two BOS tokens live
  2. the prefill logits, which is the backbone and the speech head
  3. the token sequence, decoded step by step with the cache
  4. the sampler, against the `LogitsProcessor` objects upstream composes
  5. the hand-written backbone that the Core ML export will trace, against the
     `transformers` one it replaces — prefill and one cached step
  6. the two export modules themselves — the assembled prompt, the state-backed
     cache and the guidance combination — against the reference loop
  7. the converted Core ML packages, when `--models` says where they are —
     both T3 halves, and the flow decoder if it has been converted too

Sampling ends up in Swift, so level 3 makes it deterministic rather than
skipping it: `torch.multinomial` is replaced by an argmax for the length of the
comparison, which leaves every other part of upstream's loop — including the
whole sampler pipeline — exactly as it is.
"""

from __future__ import annotations

import argparse
import contextlib
from pathlib import Path

import numpy as np
import torch

from common import load_multilingual
from mtl_reference import MultilingualReference, SamplingOptions

TEXT = "The quiet harbour town woke slowly. Gulls turned above the jetty."


def report(name: str, got, want, atol=1e-4) -> bool:
    """One line per comparison, with the number that decides it."""
    got, want = torch.as_tensor(got).float(), torch.as_tensor(want).float()
    if got.shape != want.shape:
        print(f"  {name:<34} FAIL  shape {tuple(got.shape)} vs {tuple(want.shape)}")
        return False
    # A filtered logit is -inf, and inf minus inf is nan rather than zero. The
    # mask and the numbers are two different claims, so they are checked as two.
    masked = torch.isinf(got)
    if not torch.equal(masked, torch.isinf(want)):
        differing = int((masked != torch.isinf(want)).sum())
        print(f"  {name:<34} FAIL  {differing} tokens filtered by one side only")
        return False
    delta = (got[~masked] - want[~masked]).abs().max().item() if (~masked).any() else 0.0
    ok = delta <= atol
    print(f"  {name:<34} {'ok  ' if ok else 'FAIL'}  max|Δ| {delta:.2e}")
    return ok


@contextlib.contextmanager
def deterministic_sampling():
    """`torch.multinomial` as an argmax, for as long as the block lasts.

    Patching the draw rather than the loop is what keeps this a test of
    upstream's code: the CFG combination, the repetition penalty, the
    temperature and both filters all still run, and only the coin toss at the
    end is replaced.
    """
    original = torch.multinomial

    def argmax(probs, num_samples=1, **kwargs):
        assert num_samples == 1
        return probs.argmax(dim=-1, keepdim=True)

    torch.multinomial = argmax
    try:
        yield
    finally:
        torch.multinomial = original


def check_prefix(model, reference, options) -> bool:
    """Level 1: the prompt, before a single layer has run."""
    print("prompt:")
    tokens = reference.text_tokens(TEXT, "en")
    mine = reference.prefix_embeds(tokens, options.cfg_weight)

    bos = model.t3.hp.start_speech_token * torch.ones_like(tokens[:, :1])
    theirs, len_cond = model.t3.prepare_input_embeds(
        t3_cond=model.conds.t3,
        text_tokens=tokens,
        speech_tokens=bos,
        cfg_weight=options.cfg_weight,
    )
    extra = model.t3.speech_emb(bos[:1]) + model.t3.speech_pos_emb.get_fixed_embedding(0)
    theirs = torch.cat([theirs, extra.expand(tokens.size(0), -1, -1)], dim=1)

    ok = report("embeddings", mine, theirs, atol=0)

    # The two structural claims the port has to hold on to, checked rather than
    # commented: the uncond row is position without content, and the prompt
    # really does end with two start-of-speech tokens at position 0.
    text_region = mine[1, len_cond:len_cond + tokens.size(1)]
    ok &= report("uncond row is positions only", text_region, model.t3.text_pos_emb(tokens), atol=0)
    ok &= report("prompt ends with two BOSes", mine[:, -1], mine[:, -2], atol=0)
    return ok


def check_prefill(model, reference, options) -> bool:
    """Level 2: one forward pass over the whole prompt."""
    print("prefill:")
    tokens = reference.text_tokens(TEXT, "en")
    embeds = reference.prefix_embeds(tokens, options.cfg_weight)

    mine, _ = reference.forward(embeds, None)
    theirs = model.t3.patched_model(
        inputs_embeds=embeds,
        past_key_values=None,
        use_cache=True,
        output_hidden_states=True,
        return_dict=True,
    ).logits

    ok = report("logits", mine, theirs, atol=1e-4)
    ok &= report(
        "argmax", mine[:, -1].argmax(-1).float(), theirs[:, -1].argmax(-1).float(), atol=0
    )
    return ok


def check_tokens(model, reference, options, steps: int) -> bool:
    """Level 3: the loop, cache and all."""
    print(f"decode ({steps} tokens):")
    tokens = reference.text_tokens(TEXT, "en")

    with deterministic_sampling():
        theirs = model.t3.inference(
            t3_cond=model.conds.t3,
            text_tokens=tokens,
            max_new_tokens=steps,
            temperature=options.temperature,
            cfg_weight=options.cfg_weight,
            repetition_penalty=options.repetition_penalty,
            min_p=options.min_p,
            top_p=options.top_p,
        )
        mine = reference.generate(TEXT, "en", max_new_tokens=steps, options=options)

    theirs = theirs[0][: mine.size(1)]
    print(f"  first tokens                       {mine[0, :8].tolist()}")
    return report("token ids", mine[0].float(), theirs.float(), atol=0)


def check_sampler(reference, options) -> bool:
    """Level 4: the filters, against the ones upstream composes."""
    from transformers.generation.logits_process import (
        MinPLogitsWarper,
        RepetitionPenaltyLogitsProcessor,
        TopPLogitsWarper,
    )

    print("sampler:")
    torch.manual_seed(0)
    logits = torch.randn(1, 8194) * 3
    generated = torch.randint(0, 8194, (1, 40))

    ok = report(
        "repetition penalty",
        reference.repetition_penalty(logits, generated, options.repetition_penalty),
        RepetitionPenaltyLogitsProcessor(penalty=options.repetition_penalty)(generated, logits.clone()),
    )
    ok &= report(
        "min-p",
        reference.min_p(logits, options.min_p),
        MinPLogitsWarper(min_p=options.min_p)(generated, logits.clone()),
    )
    for mass in [0.95, 0.8]:
        ok &= report(
            f"top-p {mass}",
            reference.top_p(logits, mass),
            TopPLogitsWarper(top_p=mass)(generated, logits.clone()),
        )

    # And the whole pipeline, in order: two rows in, one distribution out.
    both = torch.stack([logits[0], logits[0] * 0.5])
    probs = reference.sample(both, generated, options)
    ok &= report("distribution is one row", torch.tensor(float(probs.size(0))), torch.tensor(1.0))
    ok &= report("probabilities sum to one", probs.sum(), torch.tensor(1.0), atol=1e-5)
    ok &= report(
        "filtered tokens have no mass",
        probs[probs < 1e-12].sum(),
        torch.tensor(0.0),
        atol=1e-12,
    )
    return ok


def check_backbone(model, reference, options) -> bool:
    """Level 5: the forward pass the export will trace.

    `mtl_backbone.Backbone` is what becomes two Core ML packages. Checking it
    against `transformers` here — before any conversion — is what makes a later
    disagreement mean "the conversion changed something" rather than "one of
    these two is wrong and it is not obvious which".
    """
    from mtl_backbone import Backbone

    print("backbone:")
    tokens = reference.text_tokens(TEXT, "en")
    embeds = reference.prefix_embeds(tokens, options.cfg_weight)
    backbone = Backbone(model.t3, max_context=embeds.shape[1] + 64).eval()

    mine, keys, values = backbone.prefill(embeds)
    theirs, cache = reference.forward(embeds, None)
    ok = report("prefill logits", mine, theirs, atol=2e-3)

    # One step against the cache, which is where a rotary position or a mask
    # off by one shows up and a prefill-only check would not.
    token = reference.cfg(theirs[:, -1], options.cfg_weight).argmax(-1, keepdim=True)
    step = reference.step_embeds(token, 0)
    mine_step, _, _ = backbone.decode(step, embeds.shape[1], keys, values)
    theirs_step, _ = reference.forward(step, cache)
    ok &= report("one cached step", mine_step, theirs_step, atol=2e-3)
    ok &= report(
        "same next token",
        mine_step[:, -1].argmax(-1).float(),
        theirs_step[:, -1].argmax(-1).float(),
        atol=0,
    )
    return ok


def check_export_modules(model, reference, options) -> bool:
    """Level 6: what actually gets traced.

    The difference between this and level 5 is everything around the layers: the
    prompt assembled from pieces rather than handed over, the KV cache as a
    fixed-size buffer written a slot at a time, and guidance folded in before
    the logits leave the model. All three are new surface, and all three are
    invisible to a check that stops at the backbone.
    """
    import mtl_t3_export as X

    print("export modules:")
    prefill, decode = X.build(model)
    tokens = reference.text_tokens(TEXT, "en")

    # Reference, for both levels of comparison.
    embeds = reference.prefix_embeds(tokens, options.cfg_weight)
    theirs, cache = reference.forward(embeds, None)

    logits, keys, values = prefill(*X.prefill_inputs(model.conds.t3, tokens[:1]))
    ok = report("prefill logits", logits, theirs[:, -1], atol=2e-3)
    ok &= report(
        "cache shape",
        torch.tensor(list(keys.shape[:3]) + [keys.shape[-1]]).float(),
        torch.tensor(
            [len(model.t3.tfmr.layers), 2, model.t3.cfg.num_attention_heads,
             model.t3.cfg.head_dim]
        ).float(),
    )

    # One step, out of the state-backed cache rather than a growing list.
    length = embeds.shape[1]
    decode.k_cache.zero_()
    decode.v_cache.zero_()
    decode.k_cache[:, :, :, :length, :] = keys
    decode.v_cache[:, :, :, :length, :] = values

    token = reference.cfg(theirs[:, -1], options.cfg_weight).argmax(-1, keepdim=True)
    mine = decode(
        token.int(),
        torch.tensor([length], dtype=torch.int32),
        torch.tensor([1], dtype=torch.int32),
        torch.tensor([options.cfg_weight], dtype=torch.float32),
    )

    step_logits, _ = reference.forward(reference.step_embeds(token, 0), cache)
    guided = reference.cfg(step_logits[:, -1], options.cfg_weight)
    ok &= report("decode logits, guided", mine, guided, atol=3e-3)
    ok &= report(
        "same next token",
        mine.argmax(-1).float(),
        guided.argmax(-1).float(),
        atol=0,
    )
    return ok


def load_package(path: Path):
    """Load an .mlpackage the way the Swift engine loads it.

    Which processors a package may use is recorded in its own metadata by the
    export: two of the four must stay off the Neural Engine — one because the
    ANE compiler takes the machine down while compiling it, the other because
    the ANE fails the inference outright — and the engine reads that field
    before loading. So does this, because a harness that loads models
    differently from the app is not checking what the app runs.
    """
    import coremltools as ct

    declared = dict(
        ct.utils.load_spec(str(path)).description.metadata.userDefined
    ).get("computeUnits", "all")
    units = {
        "all": ct.ComputeUnit.ALL,
        "cpu_gpu": ct.ComputeUnit.CPU_AND_GPU,
        "cpu": ct.ComputeUnit.CPU_ONLY,
    }.get(declared, ct.ComputeUnit.ALL)
    return ct.models.MLModel(str(path), compute_units=units)


def correlation(got, want) -> float:
    """How much of the same shape two vectors have.

    The measure `verify_parity.py` uses for Nano, and for the same reason: the
    converted graph runs in float16, so an absolute difference on a logit says
    little, while a correlation below 0.999 means the distribution moved.
    """
    got, want = np.asarray(got, np.float64).ravel(), np.asarray(want, np.float64).ravel()
    denom = np.linalg.norm(got) * np.linalg.norm(want)
    return float(got @ want / denom) if denom else 1.0


def check_coreml(model, reference, options, models: Path, steps: int) -> bool:
    """Level 7: the converted packages, against torch.

    Everything above this line runs in float32 on the CPU. This is the first
    level where the numbers are allowed to differ, so it is measured by
    correlation, by per-step logit drift, and by whether the two loops pick the
    same token where the choice is not a coin toss.
    """
    import coremltools as ct

    import mtl_t3_export as X

    print("core ml:")
    # The prefill is loaded away from the Neural Engine deliberately. Compiling
    # a flexible text dimension over thirty layers for the ANE is what takes a
    # 16 GB machine down — with no exception, just a dead process — and it is
    # the same choice the Swift side has to make in its `MLModelConfiguration`.
    # The package records it in `computeUnits` so that is one fewer thing to
    # rediscover.
    prefill = load_package(models / "MTLT3Prefill.mlpackage")
    decode = load_package(models / "MTLT3Decode.mlpackage")

    tokens = reference.text_tokens(TEXT, "en")
    inputs = X.prefill_inputs(model.conds.t3, tokens[:1])
    names = ("speaker_emb", "prompt_tokens", "text_tokens", "emotion")
    out = prefill.predict(
        {
            name: tensor.numpy().astype(np.float32 if tensor.is_floating_point() else np.int32)
            for name, tensor in zip(names, inputs)
        }
    )

    embeds = reference.prefix_embeds(tokens, options.cfg_weight)
    torch_logits, cache = reference.forward(embeds, None)
    score = correlation(out["logits"][0], torch_logits[0, -1].numpy())
    print(f"  prefill logits                     {'ok  ' if score > 0.999 else 'FAIL'}  corr {score:.6f}")
    ok = score > 0.999

    # Seed the decode state with the cache prefill just produced. This is the
    # one piece of glue Core ML does not do, and the same two writes happen on
    # the Swift side.
    length = embeds.shape[1]
    state = decode.make_state()
    for name in ("k_cache", "v_cache"):
        buffer = np.zeros_like(state.read_state(name))
        buffer[:, :, :, :length, :] = out[name]
        state.write_state(name, buffer)

    # Both loops, in lockstep, comparing distributions rather than only the
    # tokens they happen to pick.
    #
    # Greedy decoding is unstable wherever the top two logits are close, and
    # "close" here means closer than float16 can represent: the converted graph
    # runs in half precision, so two candidates a ten-thousandth apart are the
    # same number to it and which one argmax returns is arbitrary. Comparing
    # token sequences blindly turns that into a failure — and worse, into a
    # failure that depends on which checkpoint is loaded, since a tie is a
    # property of the weights. So a mismatch is only a fault when the two
    # candidates are further apart than the drift between the two
    # implementations, measured here rather than assumed.
    guided_torch = reference.cfg(torch_logits[:, -1], options.cfg_weight)[0]
    guided_coreml = reference.cfg(torch.tensor(out["logits"]), options.cfg_weight)[0]

    # By correlation, not by absolute difference. An int8 build's logits sit a
    # quarter of a unit away from torch's where a float16 build's sit a
    # thirtieth — both are the same distribution, and a fixed tolerance here
    # would just be a statement about which quantisation was in fashion when it
    # was written. What has to hold is the shape, and then the tie-aware walk
    # below decides whether the drift is big enough to matter for the tokens.
    first = correlation(guided_coreml.numpy(), guided_torch.numpy())
    print(
        f"  first token logits                 {'ok  ' if first > 0.999 else 'FAIL'}"
        f"  corr {first:.6f}"
    )
    ok = ok and first > 0.999

    got, want, ties = [], [], 0
    drift = 0.0
    for index in range(steps):
        mine = int(guided_coreml.argmax())
        theirs = int(guided_torch.argmax())
        got.append(mine)
        want.append(theirs)
        drift = max(drift, float((guided_coreml - guided_torch).abs().max()))

        if mine != theirs:
            gap = abs(float(guided_torch[mine] - guided_torch[theirs]))
            if gap <= 3 * drift:
                ties += 1
            else:
                print(
                    f"  step {index + 1:<28} FAIL  {mine} vs {theirs}, "
                    f"{gap:.4f} apart (drift {drift:.4f})"
                )
                ok = False

        # Both sides carry on from torch's choice, so one arbitrary tie does not
        # send the two loops down different sentences.
        token = torch.tensor([[theirs]])
        torch_logits, cache = reference.forward(reference.step_embeds(token, index), cache)
        guided_torch = reference.cfg(torch_logits[:, -1], options.cfg_weight)[0]
        guided_coreml = torch.tensor(
            decode.predict(
                {
                    "token": np.array([[theirs]], dtype=np.int32),
                    "position": np.array([length + index], dtype=np.int32),
                    "speech_position": np.array([index + 1], dtype=np.int32),
                    "cfg_weight": np.array([options.cfg_weight], dtype=np.float32),
                },
                state=state,
            )["logits"]
        )[0]

    print(f"  decode tokens                      {got}")
    print(f"                                  vs {want}", end="")
    print(f"  ok (drift {drift:.4f}" + (f", {ties} tie(s))" if ties else ")"))
    return ok


def check_coreml_flow(model, models: Path) -> bool:
    """The mel decoder, converted, against torch.

    Sized from the package's own metadata rather than from constants here: the
    flow is traced at one window length and one reference-clip length, and which
    ones is a property of the file.
    """
    import coremltools as ct

    import mtl_s3_export as S

    path = models / "MTLS3Flow.mlpackage"
    if not path.exists():
        # A verification asked for against models that are not there must
        # fail, not shrug: a green run over an empty folder reads as parity.
        print(f"core ml flow: MISSING — {path} does not exist")
        return False

    print("core ml flow:")
    flow_model = load_package(path)
    meta = flow_model.user_defined_metadata
    gen_tokens = int(meta["genTokens"])
    prompt_tokens = int(meta["promptTokenLen"])
    frames = int(meta["melFrames"])

    torch.manual_seed(0)
    # Detached: the checkpoint's conditioning tensors still carry grad, and
    # `.numpy()` refuses on those.
    gen = {
        key: value.detach() if torch.is_tensor(value) else value
        for key, value in model.conds.gen.items()
    }

    def fit(tensor, length, dim):
        """Trim or pad to the length the export was traced at.

        The same operation `export_voices.fit` performs when it writes a
        `.voice` file — the built-in voice's clip is shorter than the ten
        seconds the flow is shaped for, so without this the model is handed 157
        tokens where it declared 250 and refuses the call.
        """
        have = tensor.shape[dim]
        if have == length:
            return tensor
        if have > length:
            return tensor.narrow(dim, 0, length)
        shape = list(tensor.shape)
        shape[dim] = length - have
        return torch.cat([tensor, torch.zeros(shape, dtype=tensor.dtype)], dim=dim)

    gen["prompt_token"] = fit(gen["prompt_token"], prompt_tokens, 1)
    gen["prompt_token_len"] = torch.tensor([prompt_tokens])
    gen["prompt_feat"] = fit(gen["prompt_feat"], prompt_tokens * 2, 1)
    tokens = torch.randint(0, 6000, (1, gen_tokens), dtype=torch.int32)
    noise = torch.randn(1, 80, frames)

    got = flow_model.predict(
        {
            "prompt_tokens": gen["prompt_token"].numpy().astype(np.int32),
            "gen_tokens": tokens.numpy().astype(np.int32),
            "prompt_feat": gen["prompt_feat"].numpy().astype(np.float32),
            "embedding": gen["embedding"].numpy().astype(np.float32),
            "noise": noise.numpy().astype(np.float32),
        }
    )["mel"]

    want_mel, want_wav = S.reference_run(model, tokens, noise, gen=gen)
    score = correlation(got, want_mel.numpy())
    # float16 through twenty estimator passes: correlation is the measure, as
    # it is for Nano's flow. Anything below this is a graph that drifted, not a
    # rounding difference.
    ok = score > 0.999
    print(f"  mel                                {'ok  ' if ok else 'FAIL'}  corr {score:.6f}")

    vocoder_path = models / "MTLS3Vocoder.mlpackage"
    if not vocoder_path.exists():
        return ok

    wav = load_package(vocoder_path).predict({"mel": got.astype(np.float32)})["waveform"]
    # Loose on purpose, as Nano's check is: the reference draws its own
    # excitation noise deep inside the source module, so this says "the same
    # speech", not "the same samples".
    ratio = float(np.std(wav)) / max(float(want_wav.std()), 1e-9)
    same_length = wav.shape[-1] == want_wav.shape[-1]
    loud_enough = 0.5 < ratio < 2.0
    print(
        f"  waveform                           {'ok  ' if same_length and loud_enough else 'FAIL'}"
        f"  {wav.shape[-1]} samples, rms x{ratio:.3f}"
    )
    return ok and same_length and loud_enough


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--tokens", type=int, default=16, help="decode steps to compare")
    ap.add_argument(
        "--models", type=Path, help="a directory of converted .mlpackages, for level 7"
    )
    ap.add_argument(
        "--only",
        choices=[
            "prompt", "prefill", "decode", "sampler", "backbone", "export", "coreml"
        ],
        help="one level only",
    )
    args = ap.parse_args()

    print("loading Chatterbox Multilingual")
    model = load_multilingual()
    reference = MultilingualReference(model)
    options = SamplingOptions()

    # `t3.inference` builds this lazily; level 2 needs it before then.
    if model.t3.patched_model is None if hasattr(model.t3, "patched_model") else True:
        from chatterbox.models.t3.inference.t3_hf_backend import T3HuggingfaceBackend

        model.t3.patched_model = T3HuggingfaceBackend(
            config=model.t3.cfg,
            llama=model.t3.tfmr,
            speech_enc=model.t3.speech_emb,
            speech_head=model.t3.speech_head,
        )

    ok = True
    with torch.inference_mode():
        if args.only in (None, "prompt"):
            ok &= check_prefix(model, reference, options)
        if args.only in (None, "prefill"):
            ok &= check_prefill(model, reference, options)
        if args.only in (None, "decode"):
            ok &= check_tokens(model, reference, options, args.tokens)
        if args.only in (None, "backbone"):
            ok &= check_backbone(model, reference, options)
        if args.only in (None, "export"):
            ok &= check_export_modules(model, reference, options)
        if args.models is not None and args.only in (None, "coreml"):
            ok &= check_coreml(model, reference, options, args.models, min(args.tokens, 8))
            ok &= check_coreml_flow(model, args.models)
    if args.only in (None, "sampler"):
        ok &= check_sampler(reference, options)

    print("PASS" if ok else "FAIL")
    raise SystemExit(0 if ok else 1)


if __name__ == "__main__":
    main()
