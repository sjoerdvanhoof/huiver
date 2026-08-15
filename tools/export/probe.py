#!/usr/bin/env python
"""Dump the shapes the export scripts have to match.

Not part of the build. It exists because every constant in export_models.py --
prefix length, cache layout, mel/token ratio -- is a property of the checkpoint
rather than of the config, and reading them off a loaded model is the only way
to be sure. Run it after bumping the chatterbox pin.
"""

import numpy as np
import torch

from chatterbox.tts_turbo import ChatterboxTurboTTS, punc_norm

m = ChatterboxTurboTTS.from_pretrained(device="cpu", nano=True)
hp = m.t3.hp

print("=== T3 ===")
print("backbone            ", hp.llama_config_name, type(m.t3.tfmr).__name__)
print("n_layer/n_head/n_emb", m.t3.cfg.n_layer, m.t3.cfg.n_head, m.t3.cfg.n_embd)
print("text vocab          ", hp.text_tokens_dict_size)
print("speech vocab        ", hp.speech_tokens_dict_size)
print("start/stop speech   ", hp.start_speech_token, hp.stop_speech_token)
print("speech_cond_prompt  ", hp.speech_cond_prompt_len)
print("input_pos_emb       ", hp.input_pos_emb)
print("has text_head       ", m.t3.text_head is not None)
print("wte deleted         ", not hasattr(m.t3.tfmr, "wte"))

print("\n=== conds (built-in voice) ===")
c = m.conds
print("speaker_emb         ", tuple(c.t3.speaker_emb.shape), c.t3.speaker_emb.dtype)
print("cond_prompt_tokens  ", tuple(c.t3.cond_prompt_speech_tokens.shape))
for k, v in c.gen.items():
    print(f"gen.{k:<16}", tuple(v.shape) if torch.is_tensor(v) else v)

print("\n=== tokenizer ===")
text = punc_norm("The quiet harbour town woke slowly.")
ids = m.tokenizer(text, return_tensors="pt").input_ids
print("text                ", repr(text))
print("ids                 ", ids.tolist())
print("len(tokenizer)      ", len(m.tokenizer))

print("\n=== prefix ===")
cond_emb = m.t3.prepare_conditioning(c.t3)
print("cond_emb            ", tuple(cond_emb.shape))
print("prefix len          ", cond_emb.shape[1] + ids.shape[1] + 1, "(cond + text + BOS speech)")

print("\n=== one forward pass ===")
start = hp.start_speech_token * torch.ones_like(ids[:, :1])
embeds, len_cond = m.t3.prepare_input_embeds(
    t3_cond=c.t3, text_tokens=ids, speech_tokens=start, cfg_weight=0.0
)
print("embeds              ", tuple(embeds.shape), "len_cond", len_cond)
with torch.inference_mode():
    out = m.t3.tfmr(inputs_embeds=embeds, use_cache=True)
past = out.past_key_values
print("past type           ", type(past).__name__)
print("past attrs          ", [a for a in dir(past) if not a.startswith("_")][:25])
layers = getattr(past, "layers", None)
if layers is not None:
    k, v = layers[0].keys, layers[0].values
    n_layers = len(layers)
else:
    k, v = past[0]
    n_layers = len(past)
print("layer0 k/v          ", tuple(k.shape), tuple(v.shape), k.dtype)
print("n layers cached     ", n_layers)

print("\n=== s3gen ===")
tokens = torch.randint(0, 6561, (1, 40))
with torch.inference_mode():
    mel = m.s3gen.flow_inference(tokens, ref_dict=dict(c.gen), n_cfm_timesteps=2)
print("mel for 40 tokens   ", tuple(mel.shape), "(token->mel ratio 2)")
with torch.inference_mode():
    wav, _ = m.s3gen.hift_inference(mel)
print("wav                 ", tuple(wav.shape), "samples per mel frame", wav.shape[-1] / mel.shape[-1])
print("trim_fade           ", tuple(m.s3gen.trim_fade.shape))
print("mel2wav f0 predictor", type(m.s3gen.mel2wav.f0_predictor).__name__)

print("\n=== param counts (fp32 MB) ===")
for name, mod in [
    ("t3.tfmr", m.t3.tfmr),
    ("t3.text_emb", m.t3.text_emb),
    ("t3.text_head", m.t3.text_head),
    ("t3.speech_emb", m.t3.speech_emb),
    ("t3.speech_head", m.t3.speech_head),
    ("t3.cond_enc", m.t3.cond_enc),
    ("s3gen.flow", m.s3gen.flow),
    ("s3gen.mel2wav", m.s3gen.mel2wav),
    ("s3gen.tokenizer", m.s3gen.tokenizer),
    ("s3gen.speaker_encoder", m.s3gen.speaker_encoder),
]:
    n = sum(p.numel() for p in mod.parameters())
    print(f"{name:<22} {n/1e6:7.1f}M  {n*4/1e6:7.1f} MB")
