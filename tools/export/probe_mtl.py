#!/usr/bin/env python
"""Dump the shapes the multilingual export has to match.

The twin of probe.py, for Chatterbox Multilingual 500M rather than Nano. Not
part of any build: it exists because every constant the export and the Swift
port depend on is a property of the checkpoint rather than of a config file, and
reading them off a loaded model is the only way to be sure.

    python probe_mtl.py

Run it after bumping the chatterbox pin in
apps/web/py/requirements-chatterbox.txt.
"""

from __future__ import annotations

import torch

from common import load_multilingual

m = load_multilingual()
t3 = m.t3
hp = t3.hp

print("=== T3 backbone ===")
print("config name         ", hp.llama_config_name, type(t3.tfmr).__name__)
print("layers/heads/dim    ", t3.cfg.num_hidden_layers, t3.cfg.num_attention_heads, t3.cfg.hidden_size)
print("head_dim/intermediate", t3.cfg.head_dim, t3.cfg.intermediate_size)
# Where RoPE's parameters live moved between transformers releases, so ask
# rather than assume — this is exactly the sort of thing the Swift port has to
# hardcode and therefore has to be sure of.
rope = {
    key: getattr(t3.cfg, key)
    for key in ["rope_theta", "rope_scaling", "rope_parameters"]
    if hasattr(t3.cfg, key)
}
print("rope                ", rope)
print("text vocab          ", hp.text_tokens_dict_size)
print("speech vocab        ", hp.speech_tokens_dict_size)
print("start/stop text     ", hp.start_text_token, hp.stop_text_token)
print("start/stop speech   ", hp.start_speech_token, hp.stop_speech_token)
print("speech_cond_prompt  ", hp.speech_cond_prompt_len)
print("input_pos_emb       ", hp.input_pos_emb)
print("emotion_adv         ", hp.emotion_adv)
print("perceiver           ", t3.cond_enc.perceiver is not None)

print("\n=== learned positions ===")
print("text_pos_emb        ", tuple(t3.text_pos_emb.emb.weight.shape))
print("speech_pos_emb      ", tuple(t3.speech_pos_emb.emb.weight.shape))

print("\n=== conditioning ===")
conds = m.conds
print("speaker_emb         ", tuple(conds.t3.speaker_emb.shape))
print("cond_prompt_tokens  ", tuple(conds.t3.cond_prompt_speech_tokens.shape))
print("emotion_adv         ", conds.t3.emotion_adv.view(-1).tolist())
cond_emb = t3.prepare_conditioning(conds.t3)
print("cond prefix         ", tuple(cond_emb.shape), "= speaker(1) + perceiver + emotion(1)")

print("\n=== tokenizer ===")
for language in ["en", "nl", "de"]:
    ids = m.tokenizer.text_to_tokens("The quiet harbour town woke slowly.", language_id=language)
    print(f"{language:<4} ids            ", ids.shape[-1], ids[0, :12].tolist())

print("\n=== one prefill, batch 2 for CFG ===")
ids = m.tokenizer.text_to_tokens("The quiet harbour town woke slowly.", language_id="en")
ids = torch.cat([ids, ids], dim=0)
ids = torch.nn.functional.pad(ids, (1, 0), value=hp.start_text_token)
ids = torch.nn.functional.pad(ids, (0, 1), value=hp.stop_text_token)
bos = hp.start_speech_token * torch.ones_like(ids[:, :1])
embeds, len_cond = t3.prepare_input_embeds(
    t3_cond=conds.t3, text_tokens=ids, speech_tokens=bos, cfg_weight=0.5
)
print("embeds              ", tuple(embeds.shape), "len_cond", len_cond)
print("uncond text is zero ", bool((embeds[1, len_cond:-1] - t3.text_pos_emb(ids)[1]).abs().max() < 1e-6),
      "(the uncond branch keeps its positions and loses its words)")

print("\n=== s3gen ===")
print("type                ", type(m.s3gen).__name__)
flow = getattr(m.s3gen, "flow", None)
if flow is not None:
    solver = getattr(flow, "decoder", None)
    print("flow decoder        ", type(solver).__name__)
    for name in ["t_scheduler", "inference_cfg_rate", "n_timesteps"]:
        if hasattr(solver, name):
            print(f"  {name:<18}", getattr(solver, name))
print("sample rate         ", m.sr)
