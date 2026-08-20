"""A second implementation of the multilingual decode loop, to disagree with.

The point is not to be faster or tidier than chatterbox's own `T3.inference`.
It is to be a *different* implementation of the same thing, written the way the
Core ML export and the Swift port will have to be — an explicit KV cache, a
batch of two for classifier-free guidance, positions computed rather than
tracked for us by `generate`, and a sampler that is code rather than a list of
`LogitsProcessor` objects. Two implementations that agree are evidence; one
implementation is a hope.

`verify_mtl.py` is what puts the two side by side. This file is only the second
opinion.

What it deliberately does *not* re-implement is the network: the perceiver
resampler, the thirty LLaMA layers and the speech head are called as they are.
Those get compared against Core ML later, module by module, the way
`verify_parity.py` does it for Nano. What is re-implemented here is everything
around them, which is precisely the part that has no weights and therefore
cannot be exported — and so is the part that will be written by hand twice, in
Python and then in Swift.
"""

from __future__ import annotations

from dataclasses import dataclass

import torch
import torch.nn.functional as F
from torch import Tensor


@dataclass
class SamplingOptions:
    """The multilingual sampler's knobs, in the order they are applied.

    The order is not the same as Nano's, and the difference is not cosmetic:
    a repetition penalty applied before the temperature divides an already
    penalised logit, and applied after it does not. `SamplingOptions` in Swift
    describes Nano's order today, which is why this is spelled out here rather
    than assumed to carry over.
    """

    cfg_weight: float = 0.5
    repetition_penalty: float = 1.2
    temperature: float = 0.8
    min_p: float = 0.05
    top_p: float = 1.0


class MultilingualReference:
    """The decode loop, written out.

    ```
    prefix = [ conditioning | text | BOS | BOS ]
               34 tokens      n      1     1
    ```

    Two things in that picture are easy to get wrong and both are load-bearing:

    * **The prefix ends with two start-of-speech tokens.** `prepare_input_embeds`
      is given one as its `speech_tokens` argument and `inference` concatenates
      another. Both carry learned position 0. It looks like a slip upstream, and
      it is what the weights were trained against — a port that "fixes" it
      produces a model that sounds nearly right, which is the worst kind of
      wrong.
    * **The unconditional branch keeps its positions.** CFG zeroes the *token*
      embeddings of the second batch row and then adds the learned position
      embeddings to both. So the uncond branch is not empty: it is position
      without content. Zeroing after the addition — the obvious reading of
      "zero the text" — is a different model.
    """

    def __init__(self, model):
        self.model = model
        self.t3 = model.t3
        self.hp = model.t3.hp

    # ------------------------------------------------------------------ input

    def text_tokens(self, text: str, language: str) -> Tensor:
        """Tokenised, bracketed by SOT/EOT, and doubled for CFG.

        The language is the first token rather than a separate input, which is
        the whole of the "languages key" the iOS README imagines. Doubling
        happens before the brackets, as upstream does it, so both rows are
        identical — they diverge later, when the uncond row's embeddings are
        zeroed.
        """
        tokens = self.model.tokenizer.text_to_tokens(text, language_id=language)
        tokens = torch.cat([tokens, tokens], dim=0)
        tokens = F.pad(tokens, (1, 0), value=self.hp.start_text_token)
        return F.pad(tokens, (0, 1), value=self.hp.stop_text_token)

    def prefix_embeds(self, text_tokens: Tensor, cfg_weight: float) -> Tensor:
        """The whole prompt as embeddings: conditioning, text, and two BOSes."""
        t3, cond = self.t3, self.model.conds.t3

        cond_emb = t3.prepare_conditioning(cond)  # (1, 34, dim)
        if cond_emb.size(0) != text_tokens.size(0):
            cond_emb = cond_emb.expand(text_tokens.size(0), -1, -1)

        text_emb = t3.text_emb(text_tokens)
        if cfg_weight > 0.0:
            text_emb = torch.cat([text_emb[:1], torch.zeros_like(text_emb[1:])])
        # Positions after the zeroing, and to both rows. See the class comment.
        text_emb = text_emb + t3.text_pos_emb(text_tokens)

        bos = self.hp.start_speech_token * torch.ones_like(text_tokens[:, :1])
        speech_emb = t3.speech_emb(bos) + t3.speech_pos_emb(bos)

        # The second BOS, with position 0 again.
        extra = t3.speech_emb(bos[:1]) + t3.speech_pos_emb.get_fixed_embedding(0)
        extra = extra.expand(text_tokens.size(0), -1, -1)

        return torch.cat([cond_emb, text_emb, speech_emb, extra], dim=1)

    def step_embeds(self, token: Tensor, index: int) -> Tensor:
        """One generated token as an embedding, for both CFG rows.

        `index` is how many tokens have been generated before this one, and the
        learned position is `index + 1` — position 0 belongs to the BOS.
        """
        t3 = self.t3
        embed = t3.speech_emb(token) + t3.speech_pos_emb.get_fixed_embedding(index + 1)
        return torch.cat([embed, embed]) if embed.size(0) == 1 else embed

    # ------------------------------------------------------------------- loop

    def forward(self, embeds: Tensor, cache):
        """One pass through the backbone and the speech head."""
        out = self.t3.tfmr(
            inputs_embeds=embeds,
            past_key_values=cache,
            use_cache=True,
            output_hidden_states=True,
            return_dict=True,
        )
        hidden = out.hidden_states[-1]
        return self.t3.speech_head(hidden), out.past_key_values

    def cfg(self, logits: Tensor, weight: float) -> Tensor:
        """Fold the two rows into one set of logits.

        `cond + w * (cond - uncond)`, which is an extrapolation away from the
        unconditional branch rather than an interpolation towards it. At w=0 it
        is the conditional model; there is no setting at which the second row is
        not computed, which is why this model costs two forward passes a token
        and belongs on the Mac.
        """
        cond, uncond = logits[0:1], logits[1:2]
        return cond + weight * (cond - uncond)

    def sample(
        self, logits: Tensor, generated: Tensor, options: SamplingOptions
    ) -> Tensor:
        """CFG, then penalty, then temperature, then min-p, then top-p.

        Written out rather than composed from `LogitsProcessor`s because this is
        what has to exist in Swift, and because the order is the part worth
        being able to read.
        """
        logits = self.cfg(logits, options.cfg_weight)
        logits = self.repetition_penalty(logits, generated, options.repetition_penalty)
        if options.temperature != 1.0:
            logits = logits / options.temperature
        logits = self.min_p(logits, options.min_p)
        logits = self.top_p(logits, options.top_p)
        return torch.softmax(logits, dim=-1)

    @staticmethod
    def repetition_penalty(logits: Tensor, generated: Tensor, penalty: float) -> Tensor:
        """Divide a seen token's logit when positive, multiply when negative.

        The sign test is not a detail: a flat `logit / penalty` would *raise*
        the probability of every token whose logit is negative, which is most of
        an 8194-wide vocabulary.
        """
        if penalty == 1.0:
            return logits
        out = logits.clone()
        seen = generated[0].unique()
        gathered = out[0, seen]
        out[0, seen] = torch.where(gathered > 0, gathered / penalty, gathered * penalty)
        return out

    @staticmethod
    def min_p(logits: Tensor, floor: float) -> Tensor:
        """Drop everything less likely than `floor` times the best token.

        Relative to the peak rather than absolute, so it prunes hard when the
        model is confident and barely at all when it is not — which is the
        opposite of what top-k does and the reason both exist.
        """
        if floor <= 0:
            return logits
        probs = torch.softmax(logits, dim=-1)
        threshold = floor * probs.max(dim=-1, keepdim=True).values
        return logits.masked_fill(probs < threshold, float("-inf"))

    @staticmethod
    def top_p(logits: Tensor, mass: float) -> Tensor:
        """Keep the smallest set of tokens whose probability sums past `mass`."""
        if mass >= 1.0:
            return logits
        ordered, indices = torch.sort(logits, descending=False)
        cumulative = ordered.softmax(dim=-1).cumsum(dim=-1)
        # `<=` on the *cumulative below* keeps the token that crosses the
        # threshold, which is the behaviour Swift's `Sampler` matches for Nano.
        remove = cumulative <= (1 - mass)
        remove[..., -1] = False
        return logits.masked_fill(remove.scatter(1, indices, remove), float("-inf"))

    def generate(
        self,
        text: str,
        language: str = "en",
        max_new_tokens: int = 1000,
        options: SamplingOptions | None = None,
        greedy: bool = False,
    ) -> Tensor:
        """Tokens out, as `T3.inference` would return them."""
        options = options or SamplingOptions()
        text_tokens = self.text_tokens(text, language)
        embeds = self.prefix_embeds(text_tokens, options.cfg_weight)

        logits, cache = self.forward(embeds, None)
        generated = torch.tensor(
            [[self.hp.start_speech_token]], dtype=torch.long, device=embeds.device
        )
        produced = []

        for index in range(max_new_tokens):
            step = logits[:, -1, :]
            if greedy:
                token = self.cfg(step, options.cfg_weight).argmax(dim=-1, keepdim=True)
            else:
                token = torch.multinomial(self.sample(step, generated, options), 1)

            produced.append(token)
            generated = torch.cat([generated, token], dim=1)
            if token.view(-1).item() == self.hp.stop_speech_token:
                break

            logits, cache = self.forward(self.step_embeds(token, index), cache)

        return torch.cat(produced, dim=1) if produced else torch.empty(1, 0, dtype=torch.long)
