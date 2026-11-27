"""``java.util`` collections and utilities implemented in Python.

Collections are Python containers too: ``ArrayList`` is a ``list``, ``HashMap`` a
``dict``, sets support ``in``/``len``/iteration and set operators, and each has
``to_bridge`` returning plain JSON-compatible data.

Deliberate differences from a JVM:
- Element and key equality is Python ``==``/``hash`` (so ``1 == 1.0 == True``), and a
  host object is compared by its Python facade.
- ``HashMap``/``HashSet`` iterate in insertion order (Java leaves the order unspecified).
- Iterators are not fail-fast: there is no ``ConcurrentModificationException``.
- ``TimeZone``/``Calendar`` week rules are those of ``Locale.US`` (weeks start on Sunday).
"""
from __future__ import annotations

import base64 as _base64
import datetime as _datetime
import functools
import heapq
import math
import os
import threading
import time
import uuid as _uuid
import weakref

from . import java_lang as _l
from .java_lang import (
    Comparable, IllegalArgumentException, IllegalStateException, IndexOutOfBoundsException, Iterable,
    JavaMeta, NullPointerException, Object, RuntimeException, UnsupportedOperationException, jstr,
)

_PYTHON = {}


class _InterfaceMeta(JavaMeta):
    def __instancecheck__(cls, instance):
        # SDK calls hand plugins Python containers where Android handed them Java ones.
        return type.__instancecheck__(cls, instance) or isinstance(instance, _PYTHON.get(cls, ()))


NoSuchElementException = _l._throwable("NoSuchElementException", RuntimeException)
ConcurrentModificationException = _l._throwable("ConcurrentModificationException", RuntimeException)
EmptyStackException = _l._throwable("EmptyStackException", RuntimeException)
InputMismatchException = _l._throwable("InputMismatchException", NoSuchElementException)
MissingResourceException = _l._throwable("MissingResourceException", RuntimeException)


def _items(source):
    """Elements of a Java collection or array argument."""
    if source is None:
        raise NullPointerException("collection is null")
    if isinstance(source, (str, bytes)):
        raise TypeError("Expected a collection")
    return list(source)


def _sort_key(comparator):
    if comparator is None:
        return None
    return functools.cmp_to_key(lambda left, right: _l.call(comparator, "compare", left, right))


def _sorted(values, comparator=None, reverse=False):
    values = list(values)
    if comparator is None:
        try:
            return sorted(values, reverse=reverse)
        except TypeError:
            return sorted(values, key=functools.cmp_to_key(_l.compare), reverse=reverse)
    return sorted(values, key=_sort_key(comparator), reverse=reverse)


class Iterator(Object):
    """Java iterator over a snapshot; ``remove`` is forwarded to the owning collection."""

    def __init__(self, values=(), remover=None):
        self._values, self._position, self._remover, self._current = list(values), 0, remover, None

    def hasNext(self):
        return self._position < len(self._values)

    def next(self):
        if self._position >= len(self._values):
            raise NoSuchElementException()
        self._current = (self._values[self._position],)
        self._position += 1
        return self._current[0]

    def remove(self):
        if self._current is None:
            raise IllegalStateException()
        if self._remover is None:
            raise UnsupportedOperationException("remove")
        self._remover(self._current[0])
        self._current = None

    def forEachRemaining(self, action):
        while self.hasNext():
            _l.call(action, "accept", self.next())

    def __iter__(self):
        return self

    def __next__(self):
        if not self.hasNext():
            raise StopIteration
        return self.next()

    # java.util.Enumeration
    hasMoreElements = hasNext
    nextElement = next


class ListIterator(Iterator):
    """Live cursor over a list."""

    def __init__(self, target, index=0):
        self._target, self._cursor, self._last = target, index, -1

    def hasNext(self):
        return self._cursor < len(self._target)

    def next(self):
        if not self.hasNext():
            raise NoSuchElementException()
        self._last = self._cursor
        self._cursor += 1
        return self._target[self._last]

    def hasPrevious(self):
        return self._cursor > 0

    def previous(self):
        if not self.hasPrevious():
            raise NoSuchElementException()
        self._cursor -= 1
        self._last = self._cursor
        return self._target[self._last]

    def nextIndex(self):
        return self._cursor

    def previousIndex(self):
        return self._cursor - 1

    def remove(self):
        if self._last < 0:
            raise IllegalStateException()
        del self._target[self._last]
        self._cursor, self._last = self._last, -1

    def set(self, value):
        if self._last < 0:
            raise IllegalStateException()
        self._target[self._last] = value

    def add(self, value):
        self._target.insert(self._cursor, value)
        self._cursor += 1
        self._last = -1

    hasMoreElements = hasNext
    nextElement = next


class Collection(Iterable, metaclass=_InterfaceMeta):
    def size(self):
        return len(self)

    def isEmpty(self):
        return len(self) == 0

    def contains(self, value):
        return value in self

    def containsAll(self, other):
        return all(item in self for item in _items(other))

    def toArray(self, *array):
        return list(self)

    def iterator(self):
        return Iterator(self, self._discard)

    def _discard(self, value):
        self.remove(value)

    def addAll(self, other):
        changed = False
        for item in _items(other):
            changed = bool(self.add(item)) or changed
        return changed

    def removeAll(self, other):
        other = _items(other)
        return self.removeIf(lambda item: item in other)

    def retainAll(self, other):
        other = _items(other)
        return self.removeIf(lambda item: item not in other)

    def removeIf(self, predicate):
        doomed = [item for item in list(self) if _l.call(predicate, "test", item)]
        for item in doomed:
            self._discard(item)
        return bool(doomed)

    def stream(self):
        raise _l.unsupported("java.util.stream is not supported")

    def toString(self):
        return "[" + ", ".join("(this Collection)" if item is self else jstr(item) for item in self) + "]"

    def to_bridge(self):
        return list(self)


class List(Collection):
    pass


class Queue(Collection):
    pass


class Deque(Queue):
    pass


class Set(Collection):
    pass


class _ListOps(List):
    """Java ``List`` methods over the Python mutable-sequence protocol."""

    def _index(self, index, extra=0):
        if not _l.is_int(index):
            raise TypeError("List index must be an int")
        if not 0 <= index < len(self) + extra:
            raise IndexOutOfBoundsException(f"Index {index} out of bounds for length {len(self)}")
        return index

    def add(self, *args):
        if len(args) == 1:
            self.insert(len(self), args[0])
            return True
        if len(args) != 2:
            raise TypeError("add takes (element) or (index, element)")
        self.insert(self._index(args[0], 1), args[1])
        return None

    def addAll(self, *args):
        if len(args) == 1:
            index, values = len(self), _items(args[0])
        elif len(args) == 2:
            index, values = self._index(args[0], 1), _items(args[1])
        else:
            raise TypeError("addAll takes (collection) or (index, collection)")
        for offset, item in enumerate(values):
            self.insert(index + offset, item)
        return bool(values)

    def get(self, index):
        return self[self._index(index)]

    def set(self, index, value):
        index = self._index(index)
        previous = self[index]
        self[index] = value
        return previous

    def remove(self, value):
        if _l.is_int(value):
            index = self._index(value)
            item = self[index]
            del self[index]
            return item
        index = self.indexOf(value)
        if index < 0:
            return False
        del self[index]
        return True

    def _discard(self, value):
        index = self.indexOf(value)
        if index >= 0:
            del self[index]

    def removeIf(self, predicate):
        doomed = [index for index in range(len(self)) if _l.call(predicate, "test", self[index])]
        for index in reversed(doomed):
            del self[index]
        return bool(doomed)

    def indexOf(self, value):
        for index in range(len(self)):
            if self[index] == value:
                return index
        return -1

    def lastIndexOf(self, value):
        for index in range(len(self) - 1, -1, -1):
            if self[index] == value:
                return index
        return -1

    def iterator(self):
        return ListIterator(self)

    def listIterator(self, index=0):
        return ListIterator(self, self._index(index, 1))

    def subList(self, start, end):
        if start < 0 or end > len(self) or start > end:
            raise IndexOutOfBoundsException(f"fromIndex: {start}, toIndex: {end}, size: {len(self)}")
        return _ListView(self, start, end)

    def sort(self, comparator=None, *, key=None, reverse=False):
        if key is not None:
            ordered = sorted(self, key=key, reverse=reverse)
        else:
            ordered = _sorted(self, comparator, reverse)
        for index, item in enumerate(ordered):
            self[index] = item

    def replaceAll(self, operator):
        for index in range(len(self)):
            self[index] = _l.call(operator, "apply", self[index])

    def _edge(self, index):
        if not len(self):
            raise NoSuchElementException()
        return self[index]

    def getFirst(self):
        return self._edge(0)

    def getLast(self):
        return self._edge(len(self) - 1)

    def addFirst(self, value):
        self.insert(0, value)

    def addLast(self, value):
        self.insert(len(self), value)

    def removeFirst(self):
        value = self._edge(0)
        del self[0]
        return value

    def removeLast(self):
        value = self._edge(len(self) - 1)
        del self[len(self) - 1]
        return value

    def equals(self, other):
        return isinstance(other, List) and list(self) == list(other)

    def hashCode(self):
        result = 1
        for item in self:
            result = (31 * result + _l.java_hash(item)) & 0xFFFFFFFF
        return _l.i32(result)


class _ListView(_ListOps):
    """A window on another list (``subList``), optionally read-only or lock-guarded."""

    def __init__(self, target, start=0, end=None, writable=True):
        self._target, self._start, self._writable = target, start, writable
        self._fixed = end is not None
        self._count = (end - start) if self._fixed else 0

    def __len__(self):
        return self._count if self._fixed else len(self._target)

    def _write(self):
        if not self._writable:
            raise UnsupportedOperationException()

    def _at(self, index):
        if not _l.is_int(index):
            raise TypeError("List index must be an int")
        size = len(self)
        if index < 0:
            index += size
        if not 0 <= index < size:
            raise IndexError("list index out of range")
        return self._start + index

    def __getitem__(self, index):
        if isinstance(index, slice):
            return list(self)[index]
        return self._target[self._at(index)]

    def __setitem__(self, index, value):
        self._write()
        self._target[self._at(index)] = value

    def __delitem__(self, index):
        self._write()
        del self._target[self._at(index)]
        self._count -= 1

    def insert(self, index, value):
        self._write()
        self._target.insert(self._start + max(0, min(index, len(self))), value)
        self._count += 1

    def append(self, value):
        self.insert(len(self), value)

    def clear(self):
        self._write()
        for index in range(len(self) - 1, -1, -1):
            del self[index]

    def __iter__(self):
        return (self._target[self._start + index] for index in range(len(self)))

    def __contains__(self, value):
        return any(item == value for item in self)

    def __eq__(self, other):
        return isinstance(other, List) and list(self) == list(other)

    __hash__ = None

    def __repr__(self):
        return repr(list(self))


class ArrayList(_ListOps, list):
    __ayu_overrides_host__ = True  # the Swift adapter is a subset; the host neither takes nor returns one
    def __init__(self, source=None):
        if source is None or _l.is_int(source):
            if _l.is_int(source) and source < 0:
                raise IllegalArgumentException(f"Illegal Capacity: {source}")
            list.__init__(self)
        else:
            list.__init__(self, _items(source))

    def ensureCapacity(self, capacity):
        return None

    def trimToSize(self):
        return None

    def clone(self):
        return type(self)(self)


class _DequeOps(Deque):
    """Queue/deque methods; the head is index 0."""

    def offer(self, value):
        self.insert(len(self), value)
        return True

    def offerFirst(self, value):
        self.insert(0, value)
        return True

    offerLast = offer

    def push(self, value):
        self.insert(0, value)

    def pop(self, *args):
        if args:
            return list.pop(self, *args)
        return self.removeFirst()

    def element(self):
        return self.getFirst()

    def peek(self):
        return self[0] if len(self) else None

    peekFirst = peek

    def peekLast(self):
        return self[len(self) - 1] if len(self) else None

    def poll(self):
        return self.removeFirst() if len(self) else None

    pollFirst = poll

    def pollLast(self):
        return self.removeLast() if len(self) else None

    def removeFirstOccurrence(self, value):
        index = self.indexOf(value)
        if index >= 0:
            del self[index]
        return index >= 0

    def removeLastOccurrence(self, value):
        index = self.lastIndexOf(value)
        if index >= 0:
            del self[index]
        return index >= 0

    def descendingIterator(self):
        return Iterator(reversed(list(self)), self._discard)


class LinkedList(_DequeOps, ArrayList):
    def remove(self, *args):
        return ArrayList.remove(self, *args) if args else self.removeFirst()


class ArrayDeque(_DequeOps, _ListOps, list):
    def __init__(self, source=None):
        list.__init__(self, () if source is None or _l.is_int(source) else _items(source))

    def add(self, value):
        if value is None:
            raise NullPointerException()
        self.insert(len(self), value)
        return True

    def remove(self, *args):
        if not args:
            return self.removeFirst()
        return self.removeFirstOccurrence(args[0])

    def clone(self):
        return ArrayDeque(self)


for _name in ("get", "set", "subList", "listIterator", "sort", "replaceAll"):
    setattr(ArrayDeque, _name, _l.Hidden(_name))


class Vector(ArrayList):
    def addElement(self, value):
        self.append(value)

    def elementAt(self, index):
        return self.get(index)

    def firstElement(self):
        return self.getFirst()

    def lastElement(self):
        return self.getLast()

    def insertElementAt(self, value, index):
        self.add(index, value)

    def setElementAt(self, value, index):
        self.set(index, value)

    def removeElementAt(self, index):
        del self[self._index(index)]

    def removeElement(self, value):
        index = self.indexOf(value)
        if index >= 0:
            del self[index]
        return index >= 0

    def removeAllElements(self):
        self.clear()

    def elements(self):
        return Iterator(self)


class Stack(Vector):
    """The top of the stack is the end of the list."""

    def push(self, value):
        self.append(value)
        return value

    def pop(self, *args):
        if args:
            return list.pop(self, *args)
        if not self:
            raise EmptyStackException()
        return list.pop(self)

    def peek(self):
        if not self:
            raise EmptyStackException()
        return self[-1]

    def empty(self):
        return not self

    def search(self, value):
        index = self.lastIndexOf(value)
        return len(self) - index if index >= 0 else -1


class PriorityQueue(Queue):
    def __init__(self, *args):
        self._comparator, self._heap, self._serial = None, [], 0
        for argument in args:
            if _l.is_int(argument):
                if argument < 1:
                    raise IllegalArgumentException()
            elif callable(argument) or hasattr(type(argument), "compare"):
                self._comparator = argument
            elif argument is not None:
                for item in _items(argument):
                    self.add(item)

    def _rank(self, value):
        if self._comparator is not None:
            return _sort_key(self._comparator)(value)
        return functools.cmp_to_key(_l.compare)(value)

    def add(self, value):
        if value is None:
            raise NullPointerException()
        self._serial += 1
        heapq.heappush(self._heap, (self._rank(value), self._serial, value))
        return True

    offer = add

    def peek(self):
        return self._heap[0][2] if self._heap else None

    def element(self):
        if not self._heap:
            raise NoSuchElementException()
        return self._heap[0][2]

    def poll(self):
        return heapq.heappop(self._heap)[2] if self._heap else None

    def remove(self, *args):
        if not args:
            if not self._heap:
                raise NoSuchElementException()
            return heapq.heappop(self._heap)[2]
        for index, entry in enumerate(self._heap):
            if entry[2] == args[0]:
                del self._heap[index]
                heapq.heapify(self._heap)
                return True
        return False

    def clear(self):
        self._heap.clear()

    def comparator(self):
        return self._comparator

    def __len__(self):
        return len(self._heap)

    def __iter__(self):
        return (entry[2] for entry in list(self._heap))

    def __contains__(self, value):
        return any(entry[2] == value for entry in self._heap)


# --- sets ----------------------------------------------------------------------------------

class _SetOps(Set):
    """Java ``Set`` methods over ``_has``/``_put``/``_drop``/``_keys``."""

    def add(self, value):
        if self._has(value):
            return False
        self._put(value)
        return True

    def remove(self, value):
        if not self._has(value):
            return False
        self._drop(value)
        return True

    def _discard(self, value):
        if self._has(value):
            self._drop(value)

    discard = _discard

    def update(self, *others):
        for other in others:
            for item in other:
                self.add(item)

    def clear(self):
        for item in list(self._keys()):
            self._drop(item)

    def clone(self):
        return type(self)(self)

    def equals(self, other):
        return self == other

    def hashCode(self):
        return _l.i32(sum(_l.java_hash(item) for item in self))

    def __contains__(self, value):
        try:
            return self._has(value)
        except TypeError:
            return False

    def __iter__(self):
        return iter(list(self._keys()))

    def __len__(self):
        return len(self._keys())

    def __eq__(self, other):
        if not isinstance(other, Set):
            return NotImplemented
        return len(self) == len(other) and all(item in other for item in self)

    __hash__ = None

    def __le__(self, other):
        return all(item in other for item in self)

    def __ge__(self, other):
        return all(item in self for item in other)

    def __or__(self, other):
        return set(self) | set(other)

    def __and__(self, other):
        return set(self) & set(other)

    def __sub__(self, other):
        return set(self) - set(other)

    def __xor__(self, other):
        return set(self) ^ set(other)

    __ror__, __rand__ = __or__, __and__

    def __repr__(self):
        return "{" + ", ".join(map(repr, self)) + "}"


class HashSet(_SetOps):
    def __init__(self, source=None, load_factor=None):
        self._data = {}
        if source is not None and not _l.is_int(source):
            for item in _items(source):
                self._data[item] = True
        elif _l.is_int(source) and source < 0:
            raise IllegalArgumentException(f"Illegal initial capacity: {source}")

    def _has(self, value):
        return value in self._data

    def _put(self, value):
        self._data[value] = True

    def _drop(self, value):
        del self._data[value]

    def _keys(self):
        return self._data.keys()

    def __len__(self):
        return len(self._data)

    def clear(self):
        self._data.clear()


class LinkedHashSet(HashSet):
    pass


class _Sorted:
    """Navigation helpers shared by ``TreeSet`` and ``TreeMap`` keys."""
    _comparator = None

    def _ordered(self):
        return _sorted(self._raw_keys(), self._comparator)

    def _cmp(self, left, right):
        if self._comparator is not None:
            return _l.call(self._comparator, "compare", left, right)
        return _l.compare(left, right)

    def _first(self, descending=False):
        keys = self._ordered()
        if not keys:
            raise NoSuchElementException()
        return keys[-1 if descending else 0]

    def _near(self, key, below, inclusive):
        best = None
        for item in self._ordered():
            order = self._cmp(item, key)
            if order == 0 and inclusive:
                return (item,)
            if below and order < 0:
                best = (item,)
            elif not below and order > 0:
                return (item,)
        return best

    def _range(self, low, low_inclusive, high, high_inclusive):
        result = []
        for item in self._ordered():
            if low is not None:
                order = self._cmp(item, low[0])
                if order < 0 or order == 0 and not low_inclusive:
                    continue
            if high is not None:
                order = self._cmp(item, high[0])
                if order > 0 or order == 0 and not high_inclusive:
                    continue
            result.append(item)
        return result

    def comparator(self):
        return self._comparator


def _is_comparator(value):
    return value is not None and (callable(value) and not isinstance(value, type) or hasattr(type(value), "compare")) \
        and not isinstance(value, (Collection, dict))


class TreeSet(_Sorted, HashSet):
    def __init__(self, source=None):
        HashSet.__init__(self)
        if _is_comparator(source):
            self._comparator = source
        elif source is not None:
            if isinstance(source, TreeSet):
                self._comparator = source._comparator
            for item in _items(source):
                self.add(item)

    def _put(self, value):
        if value is None and self._comparator is None:
            raise NullPointerException()
        self._data[value] = True

    def _raw_keys(self):
        return self._data.keys()

    def _keys(self):
        return self._ordered()

    def first(self):
        return self._first()

    def last(self):
        return self._first(True)

    getFirst, getLast = first, last

    def _pick(self, found):
        return found[0] if found else None

    def floor(self, value):
        return self._pick(self._near(value, True, True))

    def lower(self, value):
        return self._pick(self._near(value, True, False))

    def ceiling(self, value):
        return self._pick(self._near(value, False, True))

    def higher(self, value):
        return self._pick(self._near(value, False, False))

    def pollFirst(self):
        if not self._data:
            return None
        value = self._first()
        del self._data[value]
        return value

    def pollLast(self):
        if not self._data:
            return None
        value = self._first(True)
        del self._data[value]
        return value

    def _snapshot(self, values):
        result = TreeSet(self._comparator)
        for item in values:
            result._data[item] = True
        return _SetView(result, writable=False)

    def headSet(self, high, inclusive=False):
        return self._snapshot(self._range(None, False, (high,), inclusive))

    def tailSet(self, low, inclusive=True):
        return self._snapshot(self._range((low,), inclusive, None, False))

    def subSet(self, low, *args):
        if len(args) == 1:
            return self._snapshot(self._range((low,), True, (args[0],), False))
        low_inclusive, high, high_inclusive = args
        return self._snapshot(self._range((low,), low_inclusive, (high,), high_inclusive))

    def descendingIterator(self):
        return Iterator(reversed(self._ordered()), self._discard)


class _SetView(_SetOps):
    """A set backed by another set or by a map's keys; optionally read-only."""

    def __init__(self, target, writable=True, growable=True, value=True):
        self._target, self._writable, self._growable, self._value = target, writable, growable, value

    def _has(self, value):
        return value in self._target

    def _put(self, value):
        if not self._writable or not self._growable:
            raise UnsupportedOperationException()
        if isinstance(self._target, Set):
            self._target.add(value)
        else:
            self._target[value] = self._value

    def _drop(self, value):
        if not self._writable:
            raise UnsupportedOperationException()
        if isinstance(self._target, Set):
            self._target.remove(value)
        else:
            del self._target[value]

    def _keys(self):
        return list(self._target)

    def clone(self):
        return HashSet(self)


# --- maps ----------------------------------------------------------------------------------

class Map(Object, metaclass=_InterfaceMeta):
    @staticmethod
    def entry(key, value):
        return SimpleEntry(key, value)


class Entry(Object):
    def getKey(self):
        return self._key

    def equals(self, other):
        return self == other

    def __eq__(self, other):
        return isinstance(other, Entry) and self.getKey() == other.getKey() and self.getValue() == other.getValue()

    def __hash__(self):
        return hash(self._key)

    def hashCode(self):
        return _l.java_hash(self.getKey()) ^ _l.java_hash(self.getValue())

    def toString(self):
        return jstr(self.getKey()) + "=" + jstr(self.getValue())

    def __iter__(self):
        return iter((self.getKey(), self.getValue()))

    def to_bridge(self):
        return [self.getKey(), self.getValue()]


Map.Entry = Entry


class SimpleEntry(Entry):
    def __init__(self, key, value=None):
        if isinstance(key, Entry) and value is None:
            key, value = key.getKey(), key.getValue()
        self._key, self._value = key, value

    def getValue(self):
        return self._value

    def setValue(self, value):
        previous, self._value = self._value, value
        return previous


class _LiveEntry(Entry):
    def __init__(self, owner, key):
        self._owner, self._key = owner, key

    def getValue(self):
        return self._owner[self._key]

    def setValue(self, value):
        previous = self._owner[self._key]
        self._owner[self._key] = value
        return previous


class _Values(Collection):
    def __init__(self, owner):
        self._owner = owner

    def __iter__(self):
        return iter([self._owner[key] for key in list(self._owner)])

    def __len__(self):
        return len(self._owner)

    def __contains__(self, value):
        return any(item == value for item in self)

    def add(self, value):
        raise UnsupportedOperationException()

    def remove(self, value):
        for key in list(self._owner):
            if self._owner[key] == value:
                del self._owner[key]
                return True
        return False

    def clear(self):
        self._owner.clear()

    def __repr__(self):
        return repr(list(self))


class _Entries(_SetOps):
    def __init__(self, owner):
        self._owner = owner

    def _has(self, value):
        return isinstance(value, Entry) and value.getKey() in self._owner and \
            self._owner[value.getKey()] == value.getValue()

    def _put(self, value):
        raise UnsupportedOperationException()

    def _drop(self, value):
        del self._owner[value.getKey()]

    def _keys(self):
        return [_LiveEntry(self._owner, key) for key in list(self._owner)]


class _MapOps(Map):
    """Java ``Map`` methods over the Python mutable-mapping protocol."""

    def size(self):
        return len(self)

    def isEmpty(self):
        return len(self) == 0

    def containsKey(self, key):
        try:
            return key in self
        except TypeError:
            return False

    def containsValue(self, value):
        return any(self[key] == value for key in list(self))

    def _lookup(self, key):
        try:
            return (self[key],) if key in self else None
        except TypeError:
            return None

    def get(self, key, default=None):
        found = self._lookup(key)
        return found[0] if found else default

    def getOrDefault(self, key, default):
        found = self._lookup(key)
        return found[0] if found else default

    def put(self, key, value):
        found = self._lookup(key)
        self[key] = value
        return found[0] if found else None

    def putAll(self, other):
        if other is None:
            raise NullPointerException()
        for key in list(other):
            self[key] = other[key]

    def putIfAbsent(self, key, value):
        found = self._lookup(key)
        if found is None or found[0] is None:
            self[key] = value
            return None
        return found[0]

    def remove(self, key, *value):
        found = self._lookup(key)
        if value:
            if found is None or found[0] != value[0]:
                return False
            del self[key]
            return True
        if found is None:
            return None
        del self[key]
        return found[0]

    def replace(self, key, *values):
        found = self._lookup(key)
        if len(values) == 2:
            if found is None or found[0] != values[0]:
                return False
            self[key] = values[1]
            return True
        if found is None:
            return None
        self[key] = values[0]
        return found[0]

    def replaceAll(self, function):
        for key in list(self):
            self[key] = _l.call(function, "apply", key, self[key])

    def computeIfAbsent(self, key, function):
        found = self._lookup(key)
        if found is not None and found[0] is not None:
            return found[0]
        value = _l.call(function, "apply", key)
        if value is not None:
            self[key] = value
        return value

    def computeIfPresent(self, key, function):
        found = self._lookup(key)
        if found is None or found[0] is None:
            return None
        value = _l.call(function, "apply", key, found[0])
        if value is None:
            del self[key]
        else:
            self[key] = value
        return value

    def compute(self, key, function):
        found = self._lookup(key)
        value = _l.call(function, "apply", key, found[0] if found else None)
        if value is None:
            if found is not None:
                del self[key]
        else:
            self[key] = value
        return value

    def merge(self, key, value, function):
        if value is None:
            raise NullPointerException()
        found = self._lookup(key)
        if found is not None and found[0] is not None:
            value = _l.call(function, "apply", found[0], value)
        if value is None:
            del self[key]
        else:
            self[key] = value
        return value

    def forEach(self, action):
        for key in list(self):
            _l.call(action, "accept", key, self[key])

    def keySet(self):
        return _SetView(self, growable=False)

    def values(self):
        return _Values(self)

    def entrySet(self):
        return _Entries(self)

    def equals(self, other):
        return isinstance(other, Map) and len(self) == len(other) and all(
            key in other and other[key] == self[key] for key in list(self))

    def hashCode(self):
        return _l.i32(sum(_l.java_hash(key) ^ _l.java_hash(self[key]) for key in list(self)))

    def toString(self):
        return "{" + ", ".join(
            ("(this Map)" if key is self else jstr(key)) + "=" +
            ("(this Map)" if self[key] is self else jstr(self[key])) for key in list(self)) + "}"

    def to_bridge(self):
        return {key: self[key] for key in list(self)}


class HashMap(_MapOps, dict):
    __ayu_overrides_host__ = True  # the Swift adapter is a subset; the host neither takes nor returns one
    def __init__(self, source=None, load_factor=None):
        dict.__init__(self)
        if _l.is_int(source):
            if source < 0:
                raise IllegalArgumentException(f"Illegal initial capacity: {source}")
        elif source is not None:
            self.putAll(source)

    def clone(self):
        return type(self)(self)


class LinkedHashMap(HashMap):
    def __init__(self, source=None, load_factor=None, access_order=False):
        self._access_order = bool(access_order)
        HashMap.__init__(self, source)

    def removeEldestEntry(self, eldest):
        return False

    def _touch(self, key):
        if self._access_order and key in self:
            dict.__setitem__(self, key, dict.pop(self, key))

    def get(self, key, default=None):
        found = self._lookup(key)
        if found:
            self._touch(key)
        return found[0] if found else default

    getOrDefault = get

    def put(self, key, value):
        previous = HashMap.put(self, key, value)
        self._touch(key)
        if len(self):
            eldest = next(iter(self))
            if self.removeEldestEntry(_LiveEntry(self, eldest)):
                dict.pop(self, eldest, None)
        return previous


class Hashtable(HashMap):
    def put(self, key, value):
        if key is None or value is None:
            raise NullPointerException()
        return HashMap.put(self, key, value)

    def __setitem__(self, key, value):
        if key is None or value is None:
            raise NullPointerException()
        dict.__setitem__(self, key, value)

    def keys(self):
        return Iterator(list(dict.keys(self)))

    def elements(self):
        return Iterator(list(dict.values(self)))

    def contains(self, value):
        return self.containsValue(value)


class TreeMap(_Sorted, HashMap):
    def __init__(self, source=None):
        HashMap.__init__(self)
        if _is_comparator(source):
            self._comparator = source
        elif source is not None:
            if isinstance(source, TreeMap):
                self._comparator = source._comparator
            self.putAll(source)

    def _raw_keys(self):
        return dict.keys(self)

    def __setitem__(self, key, value):
        if key is None and self._comparator is None:
            raise NullPointerException()
        dict.__setitem__(self, key, value)

    def __iter__(self):
        return iter(self._ordered())

    def __reversed__(self):
        return reversed(self._ordered())

    def keys(self):
        return self._ordered()

    def items(self):
        return [(key, self[key]) for key in self._ordered()]

    def __repr__(self):
        return "{" + ", ".join(f"{key!r}: {value!r}" for key, value in self.items()) + "}"

    def firstKey(self):
        return self._first()

    def lastKey(self):
        return self._first(True)

    def _entry(self, found):
        return SimpleEntry(found[0], self[found[0]]) if found else None

    def firstEntry(self):
        return self._entry((self._first(),)) if len(self) else None

    def lastEntry(self):
        return self._entry((self._first(True),)) if len(self) else None

    def pollFirstEntry(self):
        entry = self.firstEntry()
        if entry is not None:
            del self[entry.getKey()]
        return entry

    def pollLastEntry(self):
        entry = self.lastEntry()
        if entry is not None:
            del self[entry.getKey()]
        return entry

    def _key(self, found):
        return found[0] if found else None

    def floorKey(self, key):
        return self._key(self._near(key, True, True))

    def lowerKey(self, key):
        return self._key(self._near(key, True, False))

    def ceilingKey(self, key):
        return self._key(self._near(key, False, True))

    def higherKey(self, key):
        return self._key(self._near(key, False, False))

    def floorEntry(self, key):
        return self._entry(self._near(key, True, True))

    def lowerEntry(self, key):
        return self._entry(self._near(key, True, False))

    def ceilingEntry(self, key):
        return self._entry(self._near(key, False, True))

    def higherEntry(self, key):
        return self._entry(self._near(key, False, False))

    def _snapshot(self, keys):
        result = TreeMap(self._comparator)
        for key in keys:
            dict.__setitem__(result, key, self[key])
        return _MapView(result, writable=False)

    def headMap(self, high, inclusive=False):
        return self._snapshot(self._range(None, False, (high,), inclusive))

    def tailMap(self, low, inclusive=True):
        return self._snapshot(self._range((low,), inclusive, None, False))

    def subMap(self, low, *args):
        if len(args) == 1:
            return self._snapshot(self._range((low,), True, (args[0],), False))
        low_inclusive, high, high_inclusive = args
        return self._snapshot(self._range((low,), low_inclusive, (high,), high_inclusive))

    def descendingKeySet(self):
        result = LinkedHashSet(reversed(self._ordered()))
        return _SetView(result, writable=False)

    def navigableKeySet(self):
        return self.keySet()


class _MapView(_MapOps):
    """A map backed by another mapping; optionally read-only."""

    def __init__(self, target, writable=True):
        self._target, self._writable = target, writable

    def _write(self):
        if not self._writable:
            raise UnsupportedOperationException()

    def __getitem__(self, key):
        return self._target[key]

    def __setitem__(self, key, value):
        self._write()
        self._target[key] = value

    def __delitem__(self, key):
        self._write()
        del self._target[key]

    def __contains__(self, key):
        return key in self._target

    def __iter__(self):
        return iter(list(self._target))

    def __len__(self):
        return len(self._target)

    def keys(self):
        return list(self._target)

    def items(self):
        return [(key, self._target[key]) for key in list(self._target)]

    def clear(self):
        self._write()
        self._target.clear()

    def __eq__(self, other):
        return isinstance(other, Map) and dict(self.items()) == dict(other)

    __hash__ = None

    def __repr__(self):
        return repr(dict(self.items()))


class _Identity:
    """Strongly held key of ``WeakHashMap`` for values Python cannot reference weakly."""


class WeakHashMap(_MapOps):
    """Keys are held weakly where Python allows it.

    Strings, numbers and host-object facades are held strongly: Java rarely collects
    the former, and a host object outlives its Python facade.
    """

    def __init__(self, source=None, load_factor=None):
        self._weak, self._strong = weakref.WeakKeyDictionary(), {}
        if source is not None and not _l.is_int(source):
            self.putAll(source)

    def _store(self, key):
        if key is None or type(key).__name__ == "RemoteObject":
            return self._strong
        try:
            weakref.ref(key)
        except TypeError:
            return self._strong
        return self._weak

    def __getitem__(self, key):
        return self._store(key)[key]

    def __setitem__(self, key, value):
        self._store(key)[key] = value

    def __delitem__(self, key):
        del self._store(key)[key]

    def __contains__(self, key):
        return key in self._store(key)

    def __iter__(self):
        return iter(list(self._strong) + list(self._weak.keys()))

    def __len__(self):
        return len(self._strong) + len(self._weak)

    def keys(self):
        return list(self)

    def items(self):
        return [(key, self[key]) for key in self]

    def clear(self):
        self._strong.clear()
        self._weak.clear()

    def __eq__(self, other):
        return self is other

    def __hash__(self):
        return id(self)

    def __repr__(self):
        return repr(dict(self.items()))


class AbstractMap(_MapOps):
    SimpleEntry = SimpleEntry


_PYTHON.update({Collection: (list, tuple, set, frozenset), List: (list, tuple), Set: (set, frozenset),
                Map: (dict,)})


# --- Arrays / Collections / Comparator / Objects / Optional --------------------------------

class Comparator(Object):
    def __init__(self, function=None):
        self._function = function

    def compare(self, left, right):
        if self._function is None:
            raise _l.missing_member(type(self), "compare")
        return self._function(left, right)

    def __call__(self, left, right):
        return self.compare(left, right)

    def reversed(self):
        return Comparator(lambda left, right: self.compare(right, left))

    def thenComparing(self, other, comparator=None):
        other = _as_comparator(other, comparator)
        return Comparator(lambda left, right: self.compare(left, right) or other.compare(left, right))

    thenComparingInt = thenComparingLong = thenComparingDouble = thenComparing

    @staticmethod
    def naturalOrder():
        return Comparator(_l.compare)

    @staticmethod
    def reverseOrder():
        return Comparator(lambda left, right: _l.compare(right, left))

    @staticmethod
    def comparing(extractor, comparator=None):
        order = _l.compare if comparator is None else lambda left, right: _l.call(comparator, "compare", left, right)
        return Comparator(lambda left, right: order(_l.call(extractor, "apply", left),
                                                    _l.call(extractor, "apply", right)))

    comparingInt = comparingLong = comparingDouble = comparing

    @staticmethod
    def nullsFirst(comparator):
        return Comparator(lambda left, right: 0 if left is None and right is None else -1 if left is None
                          else 1 if right is None else _l.call(comparator, "compare", left, right))

    @staticmethod
    def nullsLast(comparator):
        return Comparator(lambda left, right: 0 if left is None and right is None else 1 if left is None
                          else -1 if right is None else _l.call(comparator, "compare", left, right))


def _as_comparator(value, comparator=None):
    if hasattr(type(value), "compare"):
        return value
    import inspect
    try:
        arity = len([item for item in inspect.signature(value).parameters.values()
                     if item.default is item.empty and item.kind in (item.POSITIONAL_ONLY, item.POSITIONAL_OR_KEYWORD)])
    except (TypeError, ValueError):
        arity = 2
    if arity == 1 or comparator is not None:
        return Comparator.comparing(value, comparator)
    return Comparator(value)


def _zero(array):
    if isinstance(array, (bytes, bytearray)):
        return 0
    values = list(array)
    if values and all(isinstance(item, bool) for item in values):
        return False
    if values and all(isinstance(item, (int, float)) and not isinstance(item, bool) for item in values):
        return 0.0 if any(isinstance(item, float) for item in values) else 0
    return None


def _array_copy(array, values):
    return _l.ByteArray(values) if isinstance(array, (bytes, bytearray)) else values


class Arrays(Object):
    def __init__(self):
        raise _l.unsupported("java.util.Arrays cannot be constructed")

    @staticmethod
    def asList(*values):
        if len(values) == 1 and isinstance(values[0], (list, tuple)):
            values = values[0]
        return ArrayList(values)

    @staticmethod
    def toString(array):
        if array is None:
            return "null"
        if isinstance(array, (bytes, bytearray)):
            array = [_l.signed(item, 8) for item in array]
        return "[" + ", ".join(jstr(item) for item in array) + "]"

    @staticmethod
    def deepToString(array):
        if array is None:
            return "null"
        return "[" + ", ".join(Arrays.deepToString(item) if isinstance(item, (list, tuple)) else jstr(item)
                               for item in array) + "]"

    @staticmethod
    def sort(array, *args):
        comparator = args[-1] if len(args) in (1, 3) else None
        start, end = (args[0], args[1]) if len(args) >= 2 else (0, len(array))
        if start > end:
            raise IllegalArgumentException(f"fromIndex({start}) > toIndex({end})")
        if start < 0 or end > len(array):
            raise _l.ArrayIndexOutOfBoundsException(f"Array index out of range: {start if start < 0 else end}")
        array[start:end] = _sorted(array[start:end], comparator)

    @staticmethod
    def fill(array, *args):
        if len(args) == 1:
            start, end, value = 0, len(array), args[0]
        else:
            start, end, value = args
            _l.check_range(start, end - start, len(array))
        for index in range(start, end):
            array[index] = value

    @staticmethod
    def copyOf(array, length):
        if length < 0:
            raise _l.NegativeArraySizeException(str(length))
        values = list(array[:length])
        return _array_copy(array, values + [_zero(array)] * (length - len(values)))

    @staticmethod
    def copyOfRange(array, start, end):
        if start > end:
            raise IllegalArgumentException(f"{start} > {end}")
        if start < 0 or start > len(array):
            raise _l.ArrayIndexOutOfBoundsException(str(start))
        values = list(array[start:end])
        return _array_copy(array, values + [_zero(array)] * (end - start - len(values)))

    @staticmethod
    def equals(left, right):
        if left is None or right is None:
            return left is right
        return list(left) == list(right)

    deepEquals = equals

    @staticmethod
    def hashCode(array):
        return 0 if array is None else _l.java_hash(list(array) if not isinstance(array, (bytes, bytearray)) else array)

    @staticmethod
    def binarySearch(array, *args):
        key = args[-1] if len(args) in (1, 3) else args[-2]
        comparator = args[-1] if len(args) in (2, 4) else None
        low, high = (args[0], args[1] - 1) if len(args) >= 3 else (0, len(array) - 1)
        order = _l.compare if comparator is None else lambda a, b: _l.call(comparator, "compare", a, b)
        while low <= high:
            middle = (low + high) // 2
            result = order(array[middle], key)
            if result < 0:
                low = middle + 1
            elif result > 0:
                high = middle - 1
            else:
                return middle
        return -(low + 1)

    @staticmethod
    def stream(*args):
        raise _l.unsupported("java.util.stream is not supported")


_GUARDED = ("__getitem__", "__setitem__", "__delitem__", "__contains__", "__len__", "__iter__")


def _locked(base):
    """A subclass of a view whose public methods hold one reentrant lock."""
    import types
    names = {name for owner in base.__mro__ if owner not in (Object, object) for name, value in vars(owner).items()
             if isinstance(value, types.FunctionType) and (not name.startswith("_") or name in _GUARDED)}

    def guard(name):
        def method(self, *args, **kwargs):
            with self._lock:
                return getattr(super(locked, self), name)(*args, **kwargs)
        return method

    locked = type(base)("Synchronized" + base.__name__.lstrip("_"), (base,), {name: guard(name) for name in names})

    def create(target):
        view = locked.__new__(locked)
        view._lock = threading.RLock()
        base.__init__(view, target)
        return view

    return create


_sync_list, _sync_set, _sync_map = _locked(_ListView), _locked(_SetView), _locked(_MapView)


class Collections(Object):
    __ayu_overrides_host__ = True  # the Swift adapter is a subset; the host neither takes nor returns one
    def __init__(self):
        raise _l.unsupported("java.util.Collections cannot be constructed")

    @staticmethod
    def sort(target, comparator=None):
        ordered = _sorted(target, comparator)
        for index, item in enumerate(ordered):
            target[index] = item

    @staticmethod
    def reverse(target):
        values = list(target)[::-1]
        for index, item in enumerate(values):
            target[index] = item

    @staticmethod
    def shuffle(target, random=None):
        values = list(target)
        if random is None:
            import random as _random
            _random.shuffle(values)
        else:
            for index in range(len(values) - 1, 0, -1):
                other = random.nextInt(index + 1)
                values[index], values[other] = values[other], values[index]
        for index, item in enumerate(values):
            target[index] = item

    @staticmethod
    def swap(target, first, second):
        target[first], target[second] = target[second], target[first]

    @staticmethod
    def fill(target, value):
        for index in range(len(target)):
            target[index] = value

    @staticmethod
    def addAll(target, *values):
        if len(values) == 1 and isinstance(values[0], (list, tuple)):
            values = values[0]
        changed = False
        for item in values:
            changed = bool(target.add(item)) or changed
        return changed

    @staticmethod
    def max(values, comparator=None):
        ordered = _sorted(_items(values), comparator)
        if not ordered:
            raise NoSuchElementException()
        return ordered[-1]

    @staticmethod
    def min(values, comparator=None):
        ordered = _sorted(_items(values), comparator)
        if not ordered:
            raise NoSuchElementException()
        return ordered[0]

    @staticmethod
    def frequency(values, value):
        return sum(1 for item in _items(values) if item == value)

    @staticmethod
    def disjoint(first, second):
        second = _items(second)
        return not any(item in second for item in _items(first))

    @staticmethod
    def binarySearch(target, key, comparator=None):
        return Arrays.binarySearch(target, key) if comparator is None else Arrays.binarySearch(target, key, comparator)

    @staticmethod
    def nCopies(count, value):
        if count < 0:
            raise IllegalArgumentException(f"List length = {count}")
        return _ListView(ArrayList([value] * count), writable=False)

    @staticmethod
    def emptyList():
        return _ListView(ArrayList(), writable=False)

    @staticmethod
    def emptySet():
        return _SetView(HashSet(), writable=False)

    @staticmethod
    def emptyMap():
        return _MapView(HashMap(), writable=False)

    @staticmethod
    def emptyIterator():
        return Iterator()

    @staticmethod
    def singletonList(value):
        return _ListView(ArrayList([value]), writable=False)

    @staticmethod
    def singleton(value):
        return _SetView(HashSet([value]), writable=False)

    @staticmethod
    def singletonMap(key, value):
        return _MapView(HashMap({key: value}), writable=False)

    @staticmethod
    def unmodifiableList(target):
        return _ListView(target, writable=False)

    @staticmethod
    def unmodifiableCollection(target):
        return _ListView(target, writable=False) if isinstance(target, List) else _SetView(target, writable=False)

    @staticmethod
    def unmodifiableSet(target):
        return _SetView(target, writable=False)

    unmodifiableSortedSet = unmodifiableSet

    @staticmethod
    def unmodifiableMap(target):
        return _MapView(target, writable=False)

    unmodifiableSortedMap = unmodifiableMap

    @staticmethod
    def synchronizedList(target):
        return _sync_list(target)

    @staticmethod
    def synchronizedCollection(target):
        return _sync_list(target) if isinstance(target, List) else _sync_set(target)

    @staticmethod
    def synchronizedSet(target):
        return _sync_set(target)

    @staticmethod
    def synchronizedMap(target):
        return _sync_map(target)

    @staticmethod
    def newSetFromMap(target):
        if len(target):
            raise IllegalArgumentException("Map is non-empty")
        return _SetView(target)

    @staticmethod
    def reverseOrder(comparator=None):
        if comparator is None:
            return Comparator.reverseOrder()
        return Comparator(lambda left, right: _l.call(comparator, "compare", right, left))

    @staticmethod
    def list(enumeration):
        return ArrayList(list(enumeration))

    @staticmethod
    def enumeration(values):
        return Iterator(_items(values))


Collections.EMPTY_LIST = _ListView(ArrayList(), writable=False)
Collections.EMPTY_SET = _SetView(HashSet(), writable=False)
Collections.EMPTY_MAP = _MapView(HashMap(), writable=False)


class Objects(Object):
    def __init__(self):
        raise _l.unsupported("java.util.Objects cannot be constructed")

    @staticmethod
    def equals(left, right):
        return _l.java_equals(left, right)

    deepEquals = equals

    @staticmethod
    def hash(*values):
        if len(values) == 1 and isinstance(values[0], (list, tuple)):
            values = values[0]
        return _l.java_hash(list(values))

    @staticmethod
    def hashCode(value):
        return _l.java_hash(value)

    @staticmethod
    def toString(value, default=None):
        return default if value is None and default is not None else jstr(value)

    @staticmethod
    def isNull(value):
        return value is None

    @staticmethod
    def nonNull(value):
        return value is not None

    @staticmethod
    def requireNonNull(value, message=None):
        if value is None:
            if message is not None and not isinstance(message, str):
                message = _l.call(message, "get")
            raise NullPointerException(*(() if message is None else (message,)))
        return value

    @staticmethod
    def requireNonNullElse(value, default):
        return value if value is not None else Objects.requireNonNull(default, "defaultObj")

    @staticmethod
    def requireNonNullElseGet(value, supplier):
        return value if value is not None else Objects.requireNonNull(_l.call(supplier, "get"), "supplier.get()")

    @staticmethod
    def compare(left, right, comparator):
        return 0 if left is right else _l.call(comparator, "compare", left, right)

    @staticmethod
    def checkIndex(index, length):
        if not 0 <= index < length:
            raise IndexOutOfBoundsException(f"Index {index} out of bounds for length {length}")
        return index


class Optional(Object):
    _EMPTY = None

    def __init__(self, *args):
        raise _l.unsupported("Use Optional.of, Optional.ofNullable or Optional.empty")

    @staticmethod
    def _make(value):
        optional = object.__new__(Optional)
        optional._value = value
        return optional

    @staticmethod
    def empty():
        if Optional._EMPTY is None:
            Optional._EMPTY = Optional._make(None)
        return Optional._EMPTY

    @staticmethod
    def of(value):
        if value is None:
            raise NullPointerException()
        return Optional._make(value)

    @staticmethod
    def ofNullable(value):
        return Optional.empty() if value is None else Optional._make(value)

    def isPresent(self):
        return self._value is not None

    def isEmpty(self):
        return self._value is None

    def get(self):
        if self._value is None:
            raise NoSuchElementException("No value present")
        return self._value

    def orElseThrow(self, supplier=None):
        if self._value is None and supplier is not None:
            raise _l.call(supplier, "get")
        return self.get()

    def orElse(self, other):
        return self._value if self._value is not None else other

    def orElseGet(self, supplier):
        return self._value if self._value is not None else _l.call(supplier, "get")

    def ifPresent(self, action):
        if self._value is not None:
            _l.call(action, "accept", self._value)

    def ifPresentOrElse(self, action, otherwise):
        if self._value is not None:
            _l.call(action, "accept", self._value)
        else:
            _l.call(otherwise, "run")

    def map(self, mapper):
        return self if self._value is None else Optional.ofNullable(_l.call(mapper, "apply", self._value))

    def flatMap(self, mapper):
        return self if self._value is None else Objects.requireNonNull(_l.call(mapper, "apply", self._value))

    def filter(self, predicate):
        return self if self._value is None or _l.call(predicate, "test", self._value) else Optional.empty()

    def __eq__(self, other):
        return isinstance(other, Optional) and self._value == other._value

    def __hash__(self):
        return hash(self._value)

    def __bool__(self):
        return self._value is not None

    def hashCode(self):
        return _l.java_hash(self._value)

    def toString(self):
        return "Optional.empty" if self._value is None else f"Optional[{jstr(self._value)}]"


# --- Locale / time -------------------------------------------------------------------------

class Locale(Object):
    """Language/country/variant value. Display names and the ISO code tables are not provided.

    The default locale comes from ``LC_ALL``/``LC_MESSAGES``/``LANG`` and is ``en_US`` when the
    process environment names none; the device language is only known to the host.
    """

    def __init__(self, language, country="", variant=""):
        if language is None or country is None or variant is None:
            raise NullPointerException()
        self._language, self._country, self._variant = language.lower(), country.upper(), variant

    def getLanguage(self):
        return self._language

    def getCountry(self):
        return self._country

    def getVariant(self):
        return self._variant

    def getScript(self):
        return ""

    def toString(self):
        if not self._language and not self._country:
            return ""
        return self._language + ("_" + self._country if self._country or self._variant else "") + \
            ("_" + self._variant if self._variant else "")

    def toLanguageTag(self):
        return "-".join(item for item in (self._language or "und", self._country, self._variant) if item)

    def __eq__(self, other):
        return isinstance(other, Locale) and self._key() == other._key()

    def _key(self):
        return self._language, self._country, self._variant

    def __hash__(self):
        return hash(self._key())

    def __repr__(self):
        return self.toString()

    def hashCode(self):
        return _l.java_hash(self.toString())

    def to_bridge(self):
        return self.toLanguageTag()

    @staticmethod
    def forLanguageTag(tag):
        parts = [item for item in tag.replace("_", "-").split("-") if item]
        language = parts[0] if parts and parts[0].lower() != "und" else ""
        country = next((item for item in parts[1:] if len(item) == 2 and item.isalpha()
                        or len(item) == 3 and item.isdigit()), "")
        return Locale(language, country)

    @staticmethod
    def of(language, country="", variant=""):
        return Locale(language, country, variant)

    @staticmethod
    def getDefault(category=None):
        chosen = _l.scoped_store("locale").get("default")
        if chosen is not None:
            return chosen
        for name in ("LC_ALL", "LC_MESSAGES", "LANG"):
            value = os.environ.get(name, "").split(".")[0].split("@")[0]
            if value and value not in ("C", "POSIX"):
                return Locale(*value.split("_")[:2])
        return Locale.US

    @staticmethod
    def setDefault(*args):
        if args[-1] is None:
            raise NullPointerException("Can't set default locale to NULL")
        _l.scoped_store("locale")["default"] = args[-1]


for _name, _value in {
        "ROOT": ("",), "ENGLISH": ("en",), "FRENCH": ("fr",), "GERMAN": ("de",), "ITALIAN": ("it",),
        "JAPANESE": ("ja",), "KOREAN": ("ko",), "CHINESE": ("zh",), "SIMPLIFIED_CHINESE": ("zh", "CN"),
        "TRADITIONAL_CHINESE": ("zh", "TW"), "FRANCE": ("fr", "FR"), "GERMANY": ("de", "DE"),
        "ITALY": ("it", "IT"), "JAPAN": ("ja", "JP"), "KOREA": ("ko", "KR"), "CHINA": ("zh", "CN"),
        "PRC": ("zh", "CN"), "TAIWAN": ("zh", "TW"), "UK": ("en", "GB"), "US": ("en", "US"),
        "CANADA": ("en", "CA"), "CANADA_FRENCH": ("fr", "CA")}.items():
    setattr(Locale, _name, Locale(*_value))

_EPOCH = _datetime.datetime(1970, 1, 1, tzinfo=_datetime.timezone.utc)
_MILLISECOND = _datetime.timedelta(milliseconds=1)
_DAYS = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
_MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")


class _SystemZone(_datetime.tzinfo):
    """The process time zone, read through the C library."""

    def _local(self, moment):
        return time.localtime(time.mktime((moment.year, moment.month, moment.day, moment.hour, moment.minute,
                                           moment.second, 0, 0, -1)))

    def utcoffset(self, moment):
        return _datetime.timedelta(seconds=self._local(moment).tm_gmtoff)

    def dst(self, moment):
        return _datetime.timedelta(hours=1 if self._local(moment).tm_isdst > 0 else 0)

    def tzname(self, moment):
        return self._local(moment).tm_zone

    def fromutc(self, moment):
        seconds = (moment.replace(tzinfo=_datetime.timezone.utc) - _EPOCH) // _datetime.timedelta(seconds=1)
        return _datetime.datetime(*time.localtime(seconds)[:6], moment.microsecond, tzinfo=self)


def to_datetime(millis, zone):
    """Aware ``datetime`` for epoch milliseconds in a ``TimeZone``."""
    try:
        moment = _datetime.datetime.fromtimestamp(millis // 1000, zone._tz)
    except (OverflowError, OSError, ValueError):
        raise IllegalArgumentException(f"Time {millis} is outside the supported range") from None
    return moment.replace(microsecond=millis % 1000 * 1000)


def from_datetime(moment):
    """Epoch milliseconds of an aware ``datetime``."""
    return (moment - _EPOCH) // _MILLISECOND


def _system_zone_id():
    name = os.environ.get("TZ", "")
    if name and not name.startswith(":") and "/" in name:
        return name
    try:
        path = os.path.realpath("/etc/localtime")
    except OSError:
        path = ""
    import re
    found = re.search(r"/zoneinfo[^/]*/(.+)", path)
    if found:
        return found.group(1)
    return _custom_id(time.localtime().tm_gmtoff // 60)


def _custom_id(minutes):
    return "GMT%s%02d:%02d" % ("-" if minutes < 0 else "+", abs(minutes) // 60, abs(minutes) % 60)


class TimeZone(Object):
    SHORT, LONG = 0, 1

    def __init__(self):
        raise _l.unsupported("Use TimeZone.getTimeZone or TimeZone.getDefault")

    @staticmethod
    def _make(identifier, tzinfo):
        zone = object.__new__(TimeZone)
        zone._id, zone._tz = identifier, tzinfo
        return zone

    @staticmethod
    def getDefault():
        chosen = _l.scoped_store("timezone").get("default")
        return chosen if chosen is not None else TimeZone._make(_system_zone_id(), _SystemZone())

    @staticmethod
    def setDefault(zone):
        _l.scoped_store("timezone")["default"] = zone

    @staticmethod
    def getTimeZone(identifier):
        if identifier is None:
            raise NullPointerException()
        if hasattr(identifier, "getId"):
            identifier = identifier.getId()
        if identifier in ("GMT", "UTC", "UT", "Z", "Etc/UTC", "Etc/GMT"):
            return TimeZone._make("UTC" if "UTC" in identifier else "GMT", _datetime.timezone.utc)
        import re
        custom = re.fullmatch(r"(?:GMT|UTC)?([+-])(\d{1,2})(?::?(\d{2}))?", identifier)
        if custom and (identifier[0] in "GU" or custom.group(3)) and int(custom.group(2)) <= 23 and \
                int(custom.group(3) or 0) <= 59:
            minutes = (int(custom.group(2)) * 60 + int(custom.group(3) or 0)) * (-1 if custom.group(1) == "-" else 1)
            return TimeZone._make(_custom_id(minutes), _datetime.timezone(_datetime.timedelta(minutes=minutes)))
        import zoneinfo
        try:
            return TimeZone._make(identifier, zoneinfo.ZoneInfo(identifier))
        except (zoneinfo.ZoneInfoNotFoundError, ValueError, OSError):
            if identifier == _system_zone_id():
                return TimeZone._make(identifier, _SystemZone())
            if not zoneinfo.available_timezones():
                raise _l.unsupported("No time zone database is available for named zones") from None
            # Java answers GMT for an identifier it does not understand.
            return TimeZone._make("GMT", _datetime.timezone.utc)

    @staticmethod
    def getAvailableIDs():
        import zoneinfo
        return sorted(zoneinfo.available_timezones())

    def getID(self):
        return self._id

    def _moment(self, millis=None):
        return to_datetime(_l.System.currentTimeMillis() if millis is None else millis, self)

    def getOffset(self, millis):
        return self._moment(millis).utcoffset() // _MILLISECOND

    def getRawOffset(self):
        moment = self._moment()
        return (moment.utcoffset() - (moment.dst() or _datetime.timedelta(0))) // _MILLISECOND

    def inDaylightTime(self, date):
        return bool(self._moment(date.getTime()).dst())

    def useDaylightTime(self):
        year = self._moment().year
        return any(bool(_datetime.datetime(year, month, 1, 12, tzinfo=self._tz).dst()) for month in range(1, 13))

    def getDSTSavings(self):
        return 3600000 if self.useDaylightTime() else 0

    def hasSameRules(self, other):
        return other is not None and (self._id == other._id or self._tz == other._tz)

    def toZoneId(self):
        from . import java_time
        return java_time.ZoneId.of(self._id)

    def clone(self):
        return TimeZone._make(self._id, self._tz)

    def __eq__(self, other):
        return isinstance(other, TimeZone) and self._id == other._id

    def __hash__(self):
        return hash(self._id)

    def hashCode(self):
        return _l.string_hash(self._id)

    def toString(self):
        return f"java.util.TimeZone[id=\"{self._id}\"]"


class Date(Comparable):
    def __init__(self, millis=None):
        if millis is None:
            millis = _l.System.currentTimeMillis()
        elif not _l.is_int(millis):
            raise TypeError("Date requires epoch milliseconds")
        self._ms = millis

    def getTime(self):
        return self._ms

    def setTime(self, millis):
        self._ms = millis

    def before(self, other):
        return self._ms < other.getTime()

    def after(self, other):
        return self._ms > other.getTime()

    def compareTo(self, other):
        return (self._ms > other.getTime()) - (self._ms < other.getTime())

    def __eq__(self, other):
        return isinstance(other, Date) and self._ms == other._ms

    def __lt__(self, other):
        return self._ms < other._ms

    def __hash__(self):
        return hash(self._ms)

    def hashCode(self):
        return _l.Long.hashCode(self._ms)

    def clone(self):
        return Date(self._ms)

    def _local(self):
        return to_datetime(self._ms, TimeZone.getDefault())

    def getYear(self):
        return self._local().year - 1900

    def getMonth(self):
        return self._local().month - 1

    def getDate(self):
        return self._local().day

    def getDay(self):
        return self._local().isoweekday() % 7

    def getHours(self):
        return self._local().hour

    def getMinutes(self):
        return self._local().minute

    def getSeconds(self):
        return self._local().second

    def getTimezoneOffset(self):
        return -(self._local().utcoffset() // _datetime.timedelta(minutes=1))

    def toInstant(self):
        from . import java_time
        return java_time.Instant.ofEpochMilli(self._ms)

    @staticmethod
    def from_(instant):
        return Date(instant.toEpochMilli())

    def toString(self):
        moment = self._local()
        return "%s %s %02d %02d:%02d:%02d %s %d" % (
            _DAYS[moment.weekday()], _MONTHS[moment.month - 1], moment.day, moment.hour, moment.minute,
            moment.second, moment.tzname() if not moment.tzname().startswith("UTC") or len(moment.tzname()) == 3
            else _custom_id(moment.utcoffset() // _datetime.timedelta(minutes=1)), moment.year)

    def to_bridge(self):
        return self._ms


setattr(Date, "from", Date.from_)


class Calendar(Comparable):
    """Gregorian calendar with Java's deferred, lenient field updates."""
    ERA, YEAR, MONTH, WEEK_OF_YEAR, WEEK_OF_MONTH, DATE, DAY_OF_MONTH, DAY_OF_YEAR, DAY_OF_WEEK = 0, 1, 2, 3, 4, 5, 5, 6, 7
    DAY_OF_WEEK_IN_MONTH, AM_PM, HOUR, HOUR_OF_DAY, MINUTE, SECOND, MILLISECOND, ZONE_OFFSET, DST_OFFSET = \
        8, 9, 10, 11, 12, 13, 14, 15, 16
    FIELD_COUNT = 17
    JANUARY, FEBRUARY, MARCH, APRIL, MAY, JUNE, JULY, AUGUST, SEPTEMBER, OCTOBER, NOVEMBER, DECEMBER, UNDECIMBER = \
        range(13)
    SUNDAY, MONDAY, TUESDAY, WEDNESDAY, THURSDAY, FRIDAY, SATURDAY = range(1, 8)
    AM, PM = 0, 1
    SHORT, LONG = 1, 2
    _SLOT = {1: 0, 2: 1, 5: 2, 11: 3, 12: 4, 13: 5, 14: 6}

    def __init__(self, zone=None, locale=None):
        if type(self) is Calendar:
            raise _l.unsupported("Use Calendar.getInstance()")
        self._zone = zone if isinstance(zone, TimeZone) else TimeZone.getDefault()
        self._ms, self._pending, self._first_day = _l.System.currentTimeMillis(), None, 1

    @staticmethod
    def getInstance(*args):
        return GregorianCalendar(*[item for item in args if isinstance(item, TimeZone)][:1])

    def _complete(self):
        if self._pending is None:
            return
        year, month, day, hour, minute, second, milli = self._pending
        year, month = year + month // 12, month % 12
        if not 1 <= year <= 9999:
            raise IllegalArgumentException(f"Year {year} is outside the supported range")
        try:
            local = _datetime.datetime(year, month + 1, 1) + _datetime.timedelta(
                days=day - 1, hours=hour, minutes=minute, seconds=second, milliseconds=milli)
            self._ms = from_datetime(local.replace(tzinfo=self._zone._tz))
        except (OverflowError, ValueError):
            raise IllegalArgumentException("Calendar field is outside the supported range") from None
        self._pending = None

    def _moment(self):
        self._complete()
        return to_datetime(self._ms, self._zone)

    def _fields(self):
        if self._pending is None:
            moment = to_datetime(self._ms, self._zone)
            self._pending = [moment.year, moment.month - 1, moment.day, moment.hour, moment.minute, moment.second,
                             moment.microsecond // 1000]
        return self._pending

    def _weekday(self, date):
        return date.isoweekday() % 7 + 1

    def _week_offset(self, date):
        return (self._weekday(date) - self._first_day) % 7

    def get(self, field):
        moment = self._moment()
        if field == Calendar.ERA:
            return 1
        if field == Calendar.YEAR:
            return moment.year
        if field == Calendar.MONTH:
            return moment.month - 1
        if field == Calendar.DATE:
            return moment.day
        if field == Calendar.DAY_OF_YEAR:
            return moment.timetuple().tm_yday
        if field == Calendar.DAY_OF_WEEK:
            return self._weekday(moment)
        if field == Calendar.DAY_OF_WEEK_IN_MONTH:
            return (moment.day - 1) // 7 + 1
        if field == Calendar.WEEK_OF_MONTH:
            return (moment.day - 1 + self._week_offset(moment.replace(day=1))) // 7 + 1
        if field == Calendar.WEEK_OF_YEAR:
            day = moment.timetuple().tm_yday - 1
            length = 366 if GregorianCalendar.isLeapYear(None, moment.year) else 365
            tail = self._week_offset(_datetime.date(moment.year + 1, 1, 1)) if moment.year < 9999 else 0
            if tail and day >= length - tail:
                return 1
            return (day + self._week_offset(_datetime.date(moment.year, 1, 1))) // 7 + 1
        if field == Calendar.AM_PM:
            return moment.hour // 12
        if field == Calendar.HOUR:
            return moment.hour % 12
        if field == Calendar.HOUR_OF_DAY:
            return moment.hour
        if field == Calendar.MINUTE:
            return moment.minute
        if field == Calendar.SECOND:
            return moment.second
        if field == Calendar.MILLISECOND:
            return moment.microsecond // 1000
        saving = moment.dst() or _datetime.timedelta(0)
        if field == Calendar.DST_OFFSET:
            return saving // _MILLISECOND
        if field == Calendar.ZONE_OFFSET:
            return (moment.utcoffset() - saving) // _MILLISECOND
        raise _l.ArrayIndexOutOfBoundsException(str(field))

    def set(self, *args):
        if len(args) == 2:
            field, value = args
            if field in Calendar._SLOT:
                self._fields()[Calendar._SLOT[field]] = value
            elif field == Calendar.DAY_OF_YEAR:
                fields = self._fields()
                fields[1], fields[2] = 0, value
            elif field == Calendar.HOUR:
                fields = self._fields()
                fields[3] = value + (12 if fields[3] % 24 >= 12 else 0)
            elif field == Calendar.AM_PM:
                fields = self._fields()
                fields[3] = fields[3] % 12 + 12 * value
            elif field == Calendar.DAY_OF_WEEK:
                current = self._week_offset(self._moment())
                self._fields()[2] += (value - self._first_day) % 7 - current
            else:
                raise _l.unsupported(f"Calendar.set is not supported for field {field}")
        elif len(args) in (3, 5, 6):
            fields = self._fields()
            fields[:len(args)] = args
        else:
            raise TypeError("Calendar.set takes (field, value) or (year, month, date[, hour, minute[, second]])")

    def add(self, field, amount):
        self._complete()
        if field in (Calendar.YEAR, Calendar.MONTH):
            fields = self._fields()
            months = fields[0] * 12 + fields[1] + (amount * 12 if field == Calendar.YEAR else amount)
            fields[0], fields[1] = months // 12, months % 12
            import calendar
            fields[2] = min(fields[2], calendar.monthrange(fields[0], fields[1] + 1)[1])
        elif field in (Calendar.DATE, Calendar.DAY_OF_YEAR, Calendar.DAY_OF_WEEK):
            self._fields()[2] += amount
        elif field in (Calendar.WEEK_OF_YEAR, Calendar.WEEK_OF_MONTH, Calendar.DAY_OF_WEEK_IN_MONTH):
            self._fields()[2] += 7 * amount
        elif field in (Calendar.HOUR, Calendar.HOUR_OF_DAY):
            self._ms += 3600000 * amount
        elif field == Calendar.AM_PM:
            self._ms += 43200000 * amount
        elif field == Calendar.MINUTE:
            self._ms += 60000 * amount
        elif field == Calendar.SECOND:
            self._ms += 1000 * amount
        elif field == Calendar.MILLISECOND:
            self._ms += amount
        else:
            raise IllegalArgumentException()

    def clear(self, field=None):
        if field is None:
            self._pending = [1970, 0, 1, 0, 0, 0, 0]
        elif field in Calendar._SLOT:
            self.set(field, {Calendar.YEAR: 1970, Calendar.DATE: 1}.get(field, 0))
        elif field in (Calendar.HOUR, Calendar.AM_PM):
            self.set(field, 0)
        else:
            raise _l.unsupported(f"Calendar.clear is not supported for field {field}")

    def getActualMaximum(self, field):
        moment = self._moment()
        if field == Calendar.DATE:
            import calendar
            return calendar.monthrange(moment.year, moment.month)[1]
        if field == Calendar.DAY_OF_YEAR:
            return 366 if GregorianCalendar.isLeapYear(None, moment.year) else 365
        fixed = {Calendar.MONTH: 11, Calendar.DAY_OF_WEEK: 7, Calendar.AM_PM: 1, Calendar.HOUR: 11,
                 Calendar.HOUR_OF_DAY: 23, Calendar.MINUTE: 59, Calendar.SECOND: 59, Calendar.MILLISECOND: 999}
        if field in fixed:
            return fixed[field]
        raise _l.unsupported(f"Calendar.getActualMaximum is not supported for field {field}")

    def getActualMinimum(self, field):
        return 1 if field in (Calendar.DATE, Calendar.DAY_OF_YEAR, Calendar.DAY_OF_WEEK, Calendar.YEAR,
                              Calendar.WEEK_OF_YEAR, Calendar.DAY_OF_WEEK_IN_MONTH) else 0

    getMinimum = getActualMinimum

    def getTime(self):
        self._complete()
        return Date(self._ms)

    def setTime(self, date):
        self._ms, self._pending = date.getTime(), None

    def getTimeInMillis(self):
        self._complete()
        return self._ms

    def setTimeInMillis(self, millis):
        self._ms, self._pending = millis, None

    def getTimeZone(self):
        return self._zone

    def setTimeZone(self, zone):
        self._complete()
        self._zone = zone

    def getFirstDayOfWeek(self):
        return self._first_day

    def setFirstDayOfWeek(self, value):
        self._first_day = value

    def getMinimalDaysInFirstWeek(self):
        return 1

    def isLenient(self):
        return True

    def setLenient(self, lenient):
        if not lenient:
            raise _l.unsupported("Non-lenient Calendar validation is not supported")

    def before(self, other):
        return isinstance(other, Calendar) and self.getTimeInMillis() < other.getTimeInMillis()

    def after(self, other):
        return isinstance(other, Calendar) and self.getTimeInMillis() > other.getTimeInMillis()

    def compareTo(self, other):
        return (self.getTimeInMillis() > other.getTimeInMillis()) - (self.getTimeInMillis() < other.getTimeInMillis())

    def __eq__(self, other):
        return isinstance(other, Calendar) and self.getTimeInMillis() == other.getTimeInMillis() and \
            self._zone == other._zone

    def __hash__(self):
        return hash(self.getTimeInMillis())

    def toInstant(self):
        return self.getTime().toInstant()

    def clone(self):
        copy = GregorianCalendar(self._zone)
        copy._ms, copy._first_day = self._ms, self._first_day
        copy._pending = None if self._pending is None else list(self._pending)
        return copy


class GregorianCalendar(Calendar):
    BC, AD = 0, 1

    def __init__(self, *args):
        Calendar.__init__(self, *[item for item in args if isinstance(item, TimeZone)][:1])
        numbers = [item for item in args if _l.is_int(item)]
        if numbers:
            if len(numbers) not in (3, 5, 6):
                raise TypeError("GregorianCalendar takes (year, month, day[, hour, minute[, second]])")
            self._pending = (numbers + [0, 0, 0])[:6] + [0]

    def isLeapYear(self, year):
        return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)

    def getGregorianChange(self):
        raise _l.unsupported("The Julian calendar cutover is not modelled")


# --- UUID / Random / Base64 / small text helpers -------------------------------------------

class UUID(Comparable):
    def __init__(self, most, least):
        self._value = _uuid.UUID(int=((most & 0xFFFFFFFFFFFFFFFF) << 64) | (least & 0xFFFFFFFFFFFFFFFF))

    @staticmethod
    def _wrap(value):
        result = object.__new__(UUID)
        result._value = value
        return result

    @staticmethod
    def randomUUID():
        return UUID._wrap(_uuid.uuid4())

    @staticmethod
    def fromString(text):
        parts = text.split("-")
        if len(parts) != 5 or not all(parts) or len(text) > 36:
            raise IllegalArgumentException("Invalid UUID string: " + text)
        try:
            numbers = [int(item, 16) for item in parts]
        except ValueError:
            raise _l.NumberFormatException(f'For input string: "{text}"') from None
        most = ((numbers[0] & 0xFFFFFFFF) << 32) | ((numbers[1] & 0xFFFF) << 16) | (numbers[2] & 0xFFFF)
        least = ((numbers[3] & 0xFFFF) << 48) | (numbers[4] & 0xFFFFFFFFFFFF)
        return UUID(most, least)

    @staticmethod
    def nameUUIDFromBytes(data):
        import hashlib
        digest = bytearray(hashlib.md5(_l.to_bytes(data)).digest())
        digest[6] = digest[6] & 0x0F | 0x30
        digest[8] = digest[8] & 0x3F | 0x80
        return UUID._wrap(_uuid.UUID(bytes=bytes(digest)))

    def getMostSignificantBits(self):
        return _l.i64(self._value.int >> 64)

    def getLeastSignificantBits(self):
        return _l.i64(self._value.int)

    def version(self):
        return (self._value.int >> 76) & 0xF

    def variant(self):
        least = self._value.int & 0xFFFFFFFFFFFFFFFF
        return least >> 61 if least >> 63 == 0 or least >> 62 == 3 else 2 if least >> 62 == 2 else 0

    def toString(self):
        return str(self._value)

    def __repr__(self):
        return str(self._value)

    def __eq__(self, other):
        return isinstance(other, UUID) and self._value == other._value

    def __hash__(self):
        return hash(self._value)

    def hashCode(self):
        value = self.getMostSignificantBits() ^ self.getLeastSignificantBits()
        return _l.i32((value >> 32) ^ value)

    def compareTo(self, other):
        mine = (self.getMostSignificantBits(), self.getLeastSignificantBits())
        theirs = (other.getMostSignificantBits(), other.getLeastSignificantBits())
        return (mine > theirs) - (mine < theirs)

    def to_bridge(self):
        return str(self._value)


class Random(Object):
    """``java.util.Random``'s documented 48-bit linear congruential generator."""
    _MASK = (1 << 48) - 1

    def __init__(self, seed=None):
        self._next_gaussian = None
        self.setSeed(int.from_bytes(os.urandom(8), "big") if seed is None else seed)

    def setSeed(self, seed):
        self._seed = (seed ^ 0x5DEECE66D) & Random._MASK
        self._next_gaussian = None

    def _next(self, bits):
        self._seed = (self._seed * 0x5DEECE66D + 0xB) & Random._MASK
        return _l.i32(self._seed >> (48 - bits))

    def nextInt(self, *args):
        if not args:
            return self._next(32)
        if len(args) == 2:
            origin, bound = args
            if origin >= bound:
                raise IllegalArgumentException("bound must be greater than origin")
            value = self._next(32)
            span = _l.i32(bound - origin)
            mask = _l.i32(span - 1)
            if span & mask == 0:
                return _l.i32((value & mask) + origin)
            if span > 0:
                half = (value & 0xFFFFFFFF) >> 1
                while True:
                    value = half % span
                    if half + mask - value <= _l.INT_MAX:
                        return value + origin
                    half = (self._next(32) & 0xFFFFFFFF) >> 1
            while not origin <= value < bound:
                value = self._next(32)
            return value
        bound = args[0]
        if bound <= 0:
            raise IllegalArgumentException("bound must be positive")
        if bound & -bound == bound:
            return _l.i32((bound * self._next(31)) >> 31)
        while True:
            bits = self._next(31)
            value = bits % bound
            if bits - value + (bound - 1) <= _l.INT_MAX:
                return value

    def nextLong(self):
        return _l.i64((self._next(32) << 32) + self._next(32))

    def nextBoolean(self):
        return self._next(1) != 0

    def nextFloat(self):
        return self._next(24) / float(1 << 24)

    def nextDouble(self):
        return ((self._next(26) << 27) + self._next(27)) * (1.0 / (1 << 53))

    def nextGaussian(self):
        if self._next_gaussian is not None:
            value, self._next_gaussian = self._next_gaussian, None
            return value
        while True:
            first, second = 2 * self.nextDouble() - 1, 2 * self.nextDouble() - 1
            size = first * first + second * second
            if 0 < size < 1:
                break
        multiplier = math.sqrt(-2 * math.log(size) / size)
        self._next_gaussian = second * multiplier
        return first * multiplier

    def nextBytes(self, target):
        data = bytearray()
        while len(data) < len(target):
            data += (self._next(32) & 0xFFFFFFFF).to_bytes(4, "little")
        _l.fill_bytes(target, 0, bytes(data[:len(target)]))


class _Encoder(Object):
    def __init__(self, url=False, mime=False, padding=True):
        self._url, self._mime, self._padding = url, mime, padding

    def encode(self, data):
        data = _l.to_bytes(data)
        encoded = _base64.urlsafe_b64encode(data) if self._url else _base64.b64encode(data)
        if not self._padding:
            encoded = encoded.rstrip(b"=")
        if self._mime:
            encoded = b"\r\n".join(encoded[index:index + 76] for index in range(0, len(encoded), 76))
        return _l.ByteArray(encoded)

    def encodeToString(self, data):
        return bytes(self.encode(data)).decode("ascii")

    def withoutPadding(self):
        return _Encoder(self._url, self._mime, False)


class _Decoder(Object):
    def __init__(self, url=False, mime=False):
        self._url, self._mime = url, mime

    def decode(self, data):
        raw = data.encode("latin-1", "replace") if isinstance(data, str) else _l.to_bytes(data)
        alphabet = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789" + (b"-_" if self._url else b"+/")
        if self._mime:
            raw = bytes(item for item in raw if item in alphabet or item == 61)
        body = raw.rstrip(b"=")
        padding = len(raw) - len(body)
        if any(item not in alphabet for item in body):
            bad = next(item for item in body if item not in alphabet)
            raise IllegalArgumentException("Illegal base64 character %x" % bad)
        if padding > 2 or len(body) % 4 == 1 or padding and (len(body) + padding) % 4:
            raise IllegalArgumentException("Input byte array has wrong 4-byte ending unit")
        body += b"=" * (-len(body) % 4)
        return _l.ByteArray(_base64.b64decode(body, altchars=b"-_" if self._url else None))


class Base64(Object):
    Encoder, Decoder = _Encoder, _Decoder

    def __init__(self):
        raise _l.unsupported("java.util.Base64 cannot be constructed")

    @staticmethod
    def getEncoder():
        return _Encoder()

    @staticmethod
    def getUrlEncoder():
        return _Encoder(url=True)

    @staticmethod
    def getMimeEncoder():
        return _Encoder(mime=True)

    @staticmethod
    def getDecoder():
        return _Decoder()

    @staticmethod
    def getUrlDecoder():
        return _Decoder(url=True)

    @staticmethod
    def getMimeDecoder():
        return _Decoder(mime=True)


class StringJoiner(Object):
    def __init__(self, delimiter, prefix="", suffix=""):
        self._delimiter, self._prefix, self._suffix = (_l._text(item) for item in (delimiter, prefix, suffix))
        self._parts, self._empty = [], None

    def add(self, value):
        self._parts.append(jstr(value))
        return self

    def setEmptyValue(self, value):
        self._empty = _l._text(value)
        return self

    def length(self):
        return _l.utf16_length(self.toString())

    def toString(self):
        if not self._parts and self._empty is not None:
            return self._empty
        return self._prefix + self._delimiter.join(self._parts) + self._suffix


class StringTokenizer(Object):
    def __init__(self, text, delimiters=" \t\n\r\f", return_delimiters=False):
        self._text, self._delimiters, self._return, self._position = _l._text(text), delimiters, return_delimiters, 0

    def _skip(self, position):
        if self._return:
            return position
        while position < len(self._text) and self._text[position] in self._delimiters:
            position += 1
        return position

    def _scan(self, position):
        start = position
        while position < len(self._text) and self._text[position] not in self._delimiters:
            position += 1
        if self._return and start == position and position < len(self._text):
            position += 1
        return position

    def hasMoreTokens(self):
        return self._skip(self._position) < len(self._text)

    def nextToken(self, delimiters=None):
        if delimiters is not None:
            self._delimiters = delimiters
        start = self._skip(self._position)
        if start >= len(self._text):
            raise NoSuchElementException()
        self._position = self._scan(start)
        return self._text[start:self._position]

    def countTokens(self):
        count, position = 0, self._position
        while True:
            position = self._skip(position)
            if position >= len(self._text):
                return count
            position = self._scan(position)
            count += 1

    hasMoreElements = hasMoreTokens
    nextElement = nextToken

    def __iter__(self):
        while self.hasMoreTokens():
            yield self.nextToken()


# --- java.util.regex -----------------------------------------------------------------------

class Pattern(Object):
    UNIX_LINES, CASE_INSENSITIVE, COMMENTS, MULTILINE, LITERAL, DOTALL = 1, 2, 4, 8, 16, 32
    UNICODE_CASE, CANON_EQ, UNICODE_CHARACTER_CLASS = 64, 128, 256

    def __init__(self, *args):
        raise _l.unsupported("Use Pattern.compile")

    @staticmethod
    def compile(regex, flags=0):
        pattern = object.__new__(Pattern)
        pattern._source, pattern._flags, pattern._compiled = regex, flags, _l.translate_regex(regex, flags)
        return pattern

    @staticmethod
    def matches(regex, text):
        return Pattern.compile(regex).matcher(text).matches()

    @staticmethod
    def quote(text):
        return "\\Q" + _l._text(text).replace("\\E", "\\E\\\\E\\Q") + "\\E"

    def pattern(self):
        return self._source

    def flags(self):
        return self._flags

    def toString(self):
        return self._source

    def matcher(self, text):
        return Matcher._make(self, _l._text(text, "input"))

    def split(self, text, limit=0):
        return _l.regex_split(self._compiled, _l._text(text, "input"), limit)

    def asPredicate(self):
        return lambda text: self._compiled.search(text) is not None


class Matcher(Object):
    """Indices are Python string indices (code points)."""

    def __init__(self, *args):
        raise _l.unsupported("Use Pattern.matcher")

    @staticmethod
    def _make(pattern, text):
        matcher = object.__new__(Matcher)
        matcher._pattern, matcher._text = pattern, text
        matcher.reset()
        return matcher

    def pattern(self):
        return self._pattern

    def reset(self, text=None):
        if text is not None:
            self._text = _l._text(text, "input")
        self._match, self._position, self._appended = None, 0, 0
        self._start, self._end = 0, len(self._text)
        return self

    def region(self, start, end):
        if start < 0 or start > len(self._text) or end < 0 or end > len(self._text) or start > end:
            raise IndexOutOfBoundsException("start" if start < 0 or start > len(self._text) else "end")
        self.reset()
        self._start, self._end, self._position = start, end, start
        return self

    def regionStart(self):
        return self._start

    def regionEnd(self):
        return self._end

    def matches(self):
        self._match = self._pattern._compiled.fullmatch(self._text, self._start, self._end)
        return self._after_match()

    def lookingAt(self):
        self._match = self._pattern._compiled.match(self._text, self._start, self._end)
        return self._after_match()

    def _after_match(self):
        if self._match is None:
            return False
        self._position = self._match.end() + (1 if self._match.end() == self._match.start() else 0)
        return True

    def find(self, start=None):
        if start is not None:
            if start < 0 or start > len(self._text):
                raise IndexOutOfBoundsException("Illegal start index")
            self.reset()
            self._position = start
        if self._position > self._end:
            self._match = None
            return False
        self._match = self._pattern._compiled.search(self._text, self._position, self._end)
        if self._match is None:
            self._position = self._end + 1
            return False
        self._position = self._match.end() + (1 if self._match.end() == self._match.start() else 0)
        return True

    def _current(self):
        if self._match is None:
            raise IllegalStateException("No match found")
        return self._match

    def _group(self, group):
        match = self._current()
        if isinstance(group, str):
            if group not in match.re.groupindex:
                raise IllegalArgumentException(f"No group with name <{group}>")
        elif not 0 <= group <= match.re.groups:
            raise IndexOutOfBoundsException(f"No group {group}")
        return match

    def group(self, group=0):
        return self._group(group).group(group)

    def start(self, group=0):
        return self._group(group).start(group)

    def end(self, group=0):
        return self._group(group).end(group)

    def groupCount(self):
        return self._pattern._compiled.groups

    def hitEnd(self):
        raise _l.unsupported("Matcher.hitEnd is not supported")

    def _replace(self, replacement, count):
        if isinstance(replacement, str):
            return self._pattern._compiled.sub(lambda match: _l.expand_replacement(match, replacement),
                                               self._text, count=count)
        raise _l.unsupported("Function-based Matcher replacement is not supported")

    def replaceAll(self, replacement):
        self.reset()
        return self._replace(replacement, 0)

    def replaceFirst(self, replacement):
        self.reset()
        return self._replace(replacement, 1)

    def appendReplacement(self, builder, replacement):
        match = self._current()
        builder.append(self._text[self._appended:match.start()])
        builder.append(_l.expand_replacement(match, replacement))
        self._appended = match.end()
        return self

    def appendTail(self, builder):
        builder.append(self._text[self._appended:])
        return builder

    def toMatchResult(self):
        result = Matcher._make(self._pattern, self._text)
        result._match = self._current()
        return result

    @staticmethod
    def quoteReplacement(text):
        return text.replace("\\", "\\\\").replace("$", "\\$")


CLASSES = _l.register({
    "java.util.Collection": Collection,
    "java.util.List": List,
    "java.util.Set": Set,
    "java.util.Queue": Queue,
    "java.util.Deque": Deque,
    "java.util.Map": Map,
    "java.util.Map$Entry": Entry,
    "java.util.AbstractMap": AbstractMap,
    "java.util.AbstractMap$SimpleEntry": SimpleEntry,
    "java.util.Iterator": Iterator,
    "java.util.ListIterator": ListIterator,
    "java.util.Enumeration": Iterator,
    "java.util.ArrayList": ArrayList,
    "java.util.LinkedList": LinkedList,
    "java.util.ArrayDeque": ArrayDeque,
    "java.util.Vector": Vector,
    "java.util.Stack": Stack,
    "java.util.PriorityQueue": PriorityQueue,
    "java.util.HashSet": HashSet,
    "java.util.LinkedHashSet": LinkedHashSet,
    "java.util.TreeSet": TreeSet,
    "java.util.HashMap": HashMap,
    "java.util.LinkedHashMap": LinkedHashMap,
    "java.util.TreeMap": TreeMap,
    "java.util.Hashtable": Hashtable,
    "java.util.WeakHashMap": WeakHashMap,
    "java.util.Comparator": Comparator,
    "java.util.Arrays": Arrays,
    "java.util.Collections": Collections,
    "java.util.Objects": Objects,
    "java.util.Optional": Optional,
    "java.util.Locale": Locale,
    "java.util.TimeZone": TimeZone,
    "java.util.Date": Date,
    "java.util.Calendar": Calendar,
    "java.util.GregorianCalendar": GregorianCalendar,
    "java.util.UUID": UUID,
    "java.util.Random": Random,
    "java.util.Base64": Base64,
    "java.util.Base64$Encoder": _Encoder,
    "java.util.Base64$Decoder": _Decoder,
    "java.util.StringJoiner": StringJoiner,
    "java.util.StringTokenizer": StringTokenizer,
    "java.util.NoSuchElementException": NoSuchElementException,
    "java.util.ConcurrentModificationException": ConcurrentModificationException,
    "java.util.EmptyStackException": EmptyStackException,
    "java.util.InputMismatchException": InputMismatchException,
    "java.util.MissingResourceException": MissingResourceException,
    "java.util.regex.Pattern": Pattern,
    "java.util.regex.Matcher": Matcher,
    "java.util.regex.MatchResult": Matcher,
    "java.util.regex.PatternSyntaxException": _l.PatternSyntaxException,
    "java.util.IllegalFormatException": _l.IllegalFormatException,
    "java.util.MissingFormatArgumentException": _l.MissingFormatArgumentException,
    "java.util.UnknownFormatConversionException": _l.UnknownFormatConversionException,
    "java.util.IllegalFormatConversionException": _l.IllegalFormatConversionException,
})
