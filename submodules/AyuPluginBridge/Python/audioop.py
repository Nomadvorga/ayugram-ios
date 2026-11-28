"""The part of CPython's ``audioop`` that plugins use, in pure Python.

CPython removed the C module in 3.13. These eight functions follow ``Modules/audioop.c``
of CPython 3.12 for sample widths 1 to 4: native byte order, the same checks, messages,
saturation and rounding. Where the C source adds a product to another term, arm64
compilers round once (a fused multiply-add); CPython's arm64 builds were measured to do
so in ``tomono`` and ``rms``, and this module does the same. Every other ``audioop``
function is absent, so using one is an ``AttributeError`` and a preflight blocker, never
a silent substitute.
"""
from __future__ import annotations

import array as _array
import math as _math
import operator as _operator
import sys as _sys

__all__ = ["error", "add", "max", "mul", "ratecv", "reverse", "rms", "tomono", "tostereo"]

# One call runs to completion on the serial Python queue, so its input and output are bounded.
MAX_FRAGMENT_BYTES = 16 * 1024 * 1024

_INT_MAX = 2**31 - 1
_MAXVALS = (0, 0x7F, 0x7FFF, 0x7FFFFF, 0x7FFFFFFF)
_MINVALS = (0, -0x80, -0x8000, -0x800000, -0x80000000)
_CODES = {1: "b", 2: "h", 4: "i" if _array.array("i").itemsize == 4 else "l"}
_LITTLE = _sys.byteorder == "little"
_builtin_max = max

try:
    from math import fma as _fma
except ImportError:  # Python older than 3.13
    from fractions import Fraction as _Fraction

    def _fma(x, y, z):
        if not (_math.isfinite(x) and _math.isfinite(y)) or z != z:
            return x * y + z
        if _math.isinf(z):
            return z
        return float(_Fraction(x) * _Fraction(y) + _Fraction(z))


class error(Exception):
    pass


def _limit(size):
    if size > MAX_FRAGMENT_BYTES:
        from ayu_bridge import BridgeError
        raise BridgeError("RESOURCE_LIMIT", "audioop fragment exceeds the per-call size limit")


def _buffer(fragment):
    try:
        view = memoryview(fragment)
    except TypeError:
        raise TypeError(f"a bytes-like object is required, not '{type(fragment).__name__}'") from None
    if not view.c_contiguous:
        raise BufferError("memoryview: underlying buffer is not C-contiguous")
    _limit(view.nbytes)
    return view.tobytes()


def _int(value):
    # Argument Clinic's ``int`` converter: an integer object that fits a C int.
    value = _operator.index(value)
    if not -_INT_MAX - 1 <= value <= _INT_MAX:
        raise OverflowError("Python int too large to convert to C int")
    return value


def _double(value):
    # ``PyFloat_AsDouble``: a float, or a number with ``__float__`` or ``__index__``.
    if isinstance(value, float):
        return float(value)
    if hasattr(type(value), "__float__"):
        return float(value)
    try:
        return float(_operator.index(value))
    except TypeError:
        raise TypeError("must be real number, not " + type(value).__name__) from None


def _check_size(width):
    if width < 1 or width > 4:
        raise error("Size should be 1, 2, 3 or 4")


def _check(data, width):
    _check_size(width)
    if len(data) % width != 0:
        raise error("not a whole number of frames")


def _samples(data, width):
    """Signed samples of a fragment, as ``GETRAWSAMPLE`` reads them."""
    if width != 3:
        return memoryview(data).cast(_CODES[width]).tolist()
    low, high = (0, 2) if _LITTLE else (2, 0)
    return [data[i + low] | data[i + 1] << 8 | (data[i + high] ^ 0x80) - 0x80 << 16 for i in range(0, len(data), 3)]


def _fragment(values, width):
    """Samples already within the width's range, as ``SETRAWSAMPLE`` writes them."""
    if width != 3:
        return _array.array(_CODES[width], values).tobytes()
    out = bytearray(3 * len(values))
    low, high = (0, 2) if _LITTLE else (2, 0)
    out[low::3] = [value & 0xFF for value in values]
    out[1::3] = [value >> 8 & 0xFF for value in values]
    out[high::3] = [value >> 16 & 0xFF for value in values]
    return bytes(out)


def _fused(x, y, z):
    """``x * y + z`` with one rounding, as arm64 compilers build that C expression."""
    try:
        return _fma(x, y, z)
    except (ValueError, OverflowError):
        # Infinities, NaNs and overflow: C yields what the separate operations yield.
        return x * y + z


def _fbound(value, minval, maxval):
    if value > maxval:
        value = maxval
    elif value < minval + 1.0:
        value = minval
    # Converting a NaN to int is undefined in C; arm64, the Android and iOS target, yields 0.
    return _math.floor(value) if value == value else 0


def max(fragment, width, /):
    """Return the maximum of the absolute value of all samples in a fragment."""
    data, width = _buffer(fragment), _int(width)
    _check(data, width)
    return _builtin_max(map(abs, _samples(data, width)), default=0)


def rms(fragment, width, /):
    """Return the root-mean-square of the fragment, i.e. sqrt(sum(S_i^2)/n)."""
    data, width = _buffer(fragment), _int(width)
    _check(data, width)
    total = 0.0
    for value in _samples(data, width):
        value = float(value)
        total = _fused(value, value, total)
    return int(_math.sqrt(total / (len(data) // width))) if data else 0


def mul(fragment, width, factor, /):
    """Return a fragment that has all samples in the original fragment multiplied by the floating-point value factor."""
    data, width, factor = _buffer(fragment), _int(width), _double(factor)
    _check(data, width)
    minval, maxval = float(_MINVALS[width]), float(_MAXVALS[width])
    return _fragment([_fbound(value * factor, minval, maxval) for value in _samples(data, width)], width)


def tomono(fragment, width, lfactor, rfactor, /):
    """Convert a stereo fragment to a mono fragment."""
    data, width, lfactor, rfactor = _buffer(fragment), _int(width), _double(lfactor), _double(rfactor)
    _check(data, width)
    if len(data) // width & 1:
        raise error("not a whole number of frames")
    minval, maxval = float(_MINVALS[width]), float(_MAXVALS[width])
    values = _samples(data, width)
    return _fragment([_fbound(_fused(float(left), lfactor, right * rfactor), minval, maxval)
                      for left, right in zip(values[0::2], values[1::2])], width)


def tostereo(fragment, width, lfactor, rfactor, /):
    """Generate a stereo fragment from a mono fragment."""
    data, width, lfactor, rfactor = _buffer(fragment), _int(width), _double(lfactor), _double(rfactor)
    _check(data, width)
    _limit(2 * len(data))
    minval, maxval = float(_MINVALS[width]), float(_MAXVALS[width])
    values = _samples(data, width)
    out = [0] * (2 * len(values))
    out[0::2] = [_fbound(value * lfactor, minval, maxval) for value in values]
    out[1::2] = [_fbound(value * rfactor, minval, maxval) for value in values]
    return _fragment(out, width)


def add(fragment1, fragment2, width, /):
    """Return a fragment which is the addition of the two samples passed as parameters."""
    first, second, width = _buffer(fragment1), _buffer(fragment2), _int(width)
    _check(first, width)
    if len(first) != len(second):
        raise error("Lengths should be the same")
    minval, maxval = _MINVALS[width], _MAXVALS[width]
    return _fragment([maxval if total > maxval else minval if total < minval else total
                      for total in map(_operator.add, _samples(first, width), _samples(second, width))], width)


def reverse(fragment, width, /):
    """Reverse the samples in a fragment and returns the modified fragment."""
    data, width = _buffer(fragment), _int(width)
    _check(data, width)
    return _fragment(_samples(data, width)[::-1], width)


def _gcd(a, b):
    while b > 0:
        a, b = b, a % b
    return a


def _state_error():
    return TypeError("ratecv(): illegal state argument")


def _state_int(value):
    # The ``i`` format of ``PyArg_ParseTuple``.
    value = _operator.index(value)
    if value > _INT_MAX:
        raise OverflowError("signed integer is greater than maximum")
    if value < -_INT_MAX - 1:
        raise OverflowError("signed integer is less than minimum")
    return value


def ratecv(fragment, width, nchannels, inrate, outrate, state, weightA=1, weightB=0, /):
    """Convert the frame rate of the input fragment."""
    data, width, nchannels = _buffer(fragment), _int(width), _int(nchannels)
    inrate, outrate, weightA, weightB = _int(inrate), _int(outrate), _int(weightA), _int(weightB)
    _check_size(width)
    if nchannels < 1:
        raise error("# of channels should be >= 1")
    if width > _INT_MAX // nchannels:
        raise OverflowError("width * nchannels too big for a C int")
    frame = width * nchannels
    if weightA < 1 or weightB < 0:
        raise error("weightA should be >= 1, weightB should be >= 0")
    if len(data) % frame != 0:
        raise error("not a whole number of frames")
    if inrate <= 0 or outrate <= 0:
        raise error("sampling rate not > 0")
    divisor = _gcd(inrate, outrate)
    inrate, outrate = inrate // divisor, outrate // divisor
    divisor = _gcd(weightA, weightB)
    weightA, weightB = weightA // divisor, weightB // divisor
    # CPython allocates two C ints per channel before it reads the state.
    _limit(8 * nchannels)
    frames = len(data) // frame
    if state is None:
        d = -outrate
        previous, current = [0] * nchannels, [0] * nchannels
    else:
        if not isinstance(state, tuple):
            raise TypeError("state must be a tuple or None")
        if len(state) != 2:
            raise _state_error()
        d = _state_int(state[0])
        if not isinstance(state[1], tuple):
            raise _state_error()
        if len(state[1]) != nchannels:
            raise error("illegal state argument")
        previous, current = [], []
        for channel in state[1]:
            if not isinstance(channel, tuple) or len(channel) != 2:
                raise _state_error()
            previous.append(_state_int(channel[0]))
            current.append(_state_int(channel[1]))
    shift = 32 - 8 * width
    samples = _samples(data, width)
    weight_a, weight_b, rate = float(weightA), float(weightB), float(outrate)
    weight = weight_a + weight_b
    channels = range(nchannels)
    budget = MAX_FRAGMENT_BYTES // width
    out = []
    position = 0
    while True:
        while d < 0:
            if frames == 0:
                # ``SETSAMPLE32`` keeps the high bytes of each 32-bit output sample. Only a forged
                # state can leave the C int range, where the C conversion is undefined; arm64 saturates.
                return (_fragment([min(_INT_MAX, _builtin_max(-_INT_MAX - 1, value)) >> shift for value in out], width),
                        (d, tuple(zip(previous, current))))
            for channel in channels:
                before = previous[channel] = current[channel]
                # A simple digital filter over the sample widened to 32 bits.
                current[channel] = int(_fused(weight_a, float(samples[position] << shift), weight_b * float(before)) / weight)
                position += 1
            frames -= 1
            d += outrate
        while d >= 0:
            if len(out) > budget:
                _limit(MAX_FRAGMENT_BYTES + 1)
            for channel in channels:
                out.append(int(_fused(float(previous[channel]), float(d),
                                      float(current[channel]) * float(outrate - d)) / rate))
            d -= inrate
