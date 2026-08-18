"""Torch ops coremltools does not know, taught to it.

Importing this module registers them; it has no other effect. Kept apart from
the export scripts so it is obvious how much of the conversion is our own
patching -- currently one op.
"""

from coremltools.converters.mil import Builder as mb
from coremltools.converters.mil.frontend.torch.ops import _get_inputs
from coremltools.converters.mil.frontend.torch.torch_op_registry import (
    register_torch_op,
)


@register_torch_op
def view_as(context, node):
    """`a.view_as(b)` -- a reshape that takes its shape from another tensor.

    Used by the conformer encoder's relative-position attention, in the shift
    that turns a matrix of absolute offsets into relative ones.
    """
    a, b = _get_inputs(context, node, expected=2)
    context.add(mb.reshape(x=a, shape=mb.shape(x=b), name=node.name))
