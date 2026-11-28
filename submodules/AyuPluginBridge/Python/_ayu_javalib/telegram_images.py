"""Python-local ``org.telegram.messenger.ImageLocation``.

A value class over TL objects, following Android's ``ImageLocation.java``. The factories that
need classes this SDK lacks (``getForSticker``, ``getForWebFile``, ``getForSecureDocument``,
``getForInstantFile``) and ``getKey`` are not implemented and refuse.
"""
from __future__ import annotations

from . import java_lang as _l
from . import telegram_messenger as _m

TLRPC = _m.TLRPC
PACKAGE = "org.telegram.messenger."
_INLINE_SIZES = (TLRPC.TL_photoStrippedSize, TLRPC.TL_photoPathSize)


def _selected_account():
    return _m._runtime().jclass(PACKAGE + "UserConfig").selectedAccount


def _size_location(size, photo_id, document_id):
    """``size.location`` as ``PhotoSize.TLdeserialize(photo_id, document_id, …)`` leaves it on Android.

    The TL layer carries no location in a size; Android's deserializer derives one from the owner
    id and the size type, and this SDK's decoder does not, so a size without one gets it here.
    """
    if size.location is not None:
        return size.location
    if not size.type or not (photo_id or document_id):
        return TLRPC.TL_fileLocationUnavailable()
    location = TLRPC.TL_fileLocationToBeDeprecated()
    location.volume_id = -(photo_id or document_id)
    location.local_id = ord(size.type[0]) + (0 if photo_id else 1000)
    return location


def _peer_photo_location(photo, big):
    """``photo_big``/``photo_small`` as Android's ``readParams`` of a profile or chat photo sets them."""
    location = photo.photo_big if big else photo.photo_small
    if location is None and photo.photo_id != 0:
        location = TLRPC.TL_fileLocationToBeDeprecated()
        location.volume_id, location.local_id = -photo.photo_id, ord("c" if big else "a")
    return location


@_m._local_arguments
class ImageLocation(_m._Java):
    TYPE_BIG, TYPE_SMALL, TYPE_STRIPPED, TYPE_VIDEO_SMALL, TYPE_VIDEO_BIG = 0, 1, 2, 3, 4

    def __init__(self):
        self.__dict__.update(
            dc_id=0, file_reference=None, key=None, iv=None, access_hash=0, location=None, path=None,
            secureDocument=None, document=None, videoSeekTo=0, photoSize=None, photo=None, photoPeerType=0,
            photoPeer=None, stickerSet=None, imageType=0, thumbVersion=0, currentSize=0, photoId=0, documentId=0,
            thumbSize=None, webFile=None, instantFile=None, _source=None)

    @staticmethod
    def getForPath(path):
        if path is None:
            return None
        result = ImageLocation()
        result.path = path
        return result

    @staticmethod
    def getForVideoPath(path):
        result = ImageLocation.getForPath(path)
        if result is not None:
            result.imageType = _m.FileLoader.IMAGE_TYPE_ANIMATION
        return result

    @staticmethod
    def _inline(photoSize):
        result = ImageLocation()
        result.photoSize = photoSize
        return result

    @staticmethod
    def getForDocument(*args):
        """``getForDocument(document)`` and ``getForDocument(PhotoSize|VideoSize, document)``."""
        if len(args) == 1:
            document = args[0]
            if document is None:
                return None
            result = ImageLocation()
            result.document, result.key, result.iv, result.currentSize = document, document.key, document.iv, document.size
            return result
        if len(args) != 2:
            raise TypeError("getForDocument(document) or getForDocument(size, document)")
        size, document = args
        if isinstance(size, _INLINE_SIZES):
            return ImageLocation._inline(size)
        if size is None or document is None:
            return None
        result = ImageLocation._for_photo(_size_location(size, 0, document.id), size.size, None, document, None,
                                          ImageLocation.TYPE_SMALL, document.dc_id, None, size.type)
        if result is not None:
            result._source = size
            if isinstance(size, TLRPC.VideoSize):
                result.imageType = (_m.FileLoader.IMAGE_TYPE_LOTTIE if size.type == "f"
                                    else _m.FileLoader.IMAGE_TYPE_ANIMATION)
        return result

    @staticmethod
    def getForPhoto(size, photo):
        """``getForPhoto(PhotoSize|VideoSize, photo)``."""
        if isinstance(size, TLRPC.VideoSize):
            if photo is None:
                return None
            result = ImageLocation._for_photo(_size_location(size, photo.id, 0), size.size, photo, None, None,
                                              ImageLocation.TYPE_SMALL, photo.dc_id, None, size.type)
            if result is not None:
                result._source = size
                result.imageType = _m.FileLoader.IMAGE_TYPE_ANIMATION
                if size.flags & 1:
                    result.videoSeekTo = int(size.video_start_ts * 1000)
            return result
        if isinstance(size, _INLINE_SIZES):
            return ImageLocation._inline(size)
        if size is None or photo is None:
            return None
        location = _size_location(size, photo.id, 0)
        result = ImageLocation._for_photo(location, size.size, photo, None, None, ImageLocation.TYPE_SMALL,
                                          photo.dc_id if photo.dc_id != 0 else location.dc_id, None, size.type)
        if result is not None:
            result._source = size
        return result

    @staticmethod
    def getForMessage(photoSize, message):
        return ImageLocation._inline(photoSize) if isinstance(photoSize, _INLINE_SIZES) else None

    @staticmethod
    def getForObject(photoSize, object):
        if isinstance(object, TLRPC.Photo):
            return ImageLocation.getForPhoto(photoSize, object)
        if isinstance(object, TLRPC.Document):
            return ImageLocation.getForDocument(photoSize, object)
        if isinstance(object, TLRPC.Message):
            return ImageLocation.getForMessage(photoSize, object)
        return None

    @staticmethod
    def getForUserOrChat(*args):
        """``getForUserOrChat([currentAccount,] object, type)``."""
        if isinstance(args[-2], TLRPC.User):
            return ImageLocation.getForUser(*args)
        if isinstance(args[-2], TLRPC.Chat):
            return ImageLocation.getForChat(*args)
        return None

    @staticmethod
    def _stripped(data):
        if data is None:
            return None
        result = ImageLocation()
        result.photoSize = TLRPC.TL_photoStrippedSize()
        result.photoSize.type = "s"
        result.photoSize.bytes = data
        return result

    @staticmethod
    def getForUser(*args):
        """``getForUser([currentAccount,] user, type)``."""
        user, kind = args[-2:]
        if user is None or user.photo is None:
            return None
        account = args[0] if len(args) == 3 else None
        if kind in (ImageLocation.TYPE_VIDEO_BIG, ImageLocation.TYPE_VIDEO_SMALL):
            return ImageLocation._user_video(_selected_account() if account is None else account, user, kind)
        if kind == ImageLocation.TYPE_STRIPPED:
            return ImageLocation._stripped(user.photo.stripped_thumb)
        location = _peer_photo_location(user.photo, kind == ImageLocation.TYPE_BIG)
        if location is None:
            return None
        if user.access_hash == 0:
            if user.fromMessageDialogId == 0 or user.fromMessageId == 0:
                return None
            peer = TLRPC.TL_inputPeerUserFromMessage()
            peer.user_id = user.id
            controller = _m.MessagesController.getInstance(_selected_account() if account is None else account)
            peer.peer = controller.getInputPeer(user.fromMessageDialogId)
            peer.msg_id = user.fromMessageId
        else:
            peer = TLRPC.TL_inputPeerUser()
            peer.user_id, peer.access_hash = user.id, user.access_hash
        result = ImageLocation._for_photo(location, 0, None, None, peer, kind,
                                          user.photo.dc_id if user.photo.dc_id != 0 else location.dc_id, None, None)
        result.photoId = user.photo.photo_id
        return result

    @staticmethod
    def _user_video(account, user, kind):
        controller = _m.MessagesController.getInstance(account)
        if not (controller.isPremiumUser(user) and user.photo.has_video):
            return None
        full = controller.getUserFull(user.id)
        if full is None:
            return None

        def videos(photo):
            return photo is not None and photo.video_sizes is not None and len(photo.video_sizes) > 0

        photo_id = user.photo.photo_id
        if user.photo.personal and videos(full.personal_photo):
            photo = full.personal_photo
        elif videos(full.profile_photo) and full.profile_photo.id == photo_id:
            photo = full.profile_photo
        elif videos(full.fallback_photo) and full.fallback_photo.id == photo_id:
            photo = full.fallback_photo
        elif videos(full.profile_photo):
            photo = full.profile_photo
        else:
            return None
        big = kind == ImageLocation.TYPE_VIDEO_BIG
        size = _m.FileLoader.getClosestVideoSizeWithSize(photo.video_sizes, 1000 if big else 100)
        if not big:
            size = next((item for item in photo.video_sizes if item.type == "p"), size)
        return ImageLocation.getForPhoto(size, photo)

    @staticmethod
    def getForChat(*args):
        """``getForChat([currentAccount,] chat, type)``."""
        chat, kind = args[-2:]
        if chat is None or chat.photo is None:
            return None
        if kind == ImageLocation.TYPE_STRIPPED:
            return ImageLocation._stripped(chat.photo.stripped_thumb)
        location = _peer_photo_location(chat.photo, kind == ImageLocation.TYPE_BIG)
        if location is None:
            return None
        if _m.ChatObject.isChannel(chat):
            if chat.access_hash == 0:
                return None
            peer = TLRPC.TL_inputPeerChannel()
            peer.channel_id, peer.access_hash = chat.id, chat.access_hash
        else:
            peer = TLRPC.TL_inputPeerChat()
            peer.chat_id = chat.id
        result = ImageLocation._for_photo(location, 0, None, None, peer, kind,
                                          chat.photo.dc_id if chat.photo.dc_id != 0 else location.dc_id, None, None)
        result.photoId = chat.photo.photo_id
        return result

    @staticmethod
    def getForLocal(location):
        if location is None:
            return None
        result = ImageLocation()
        result.location = TLRPC.TL_fileLocationToBeDeprecated()
        for name in ("local_id", "volume_id", "secret", "dc_id"):
            setattr(result.location, name, getattr(location, name))
        return result

    @staticmethod
    def _for_photo(location, size, photo, document, photoPeer, photoPeerType, dc_id, stickerSet, thumbSize):
        if location is None or photo is None and photoPeer is None and stickerSet is None and document is None:
            return None
        result = ImageLocation()
        result.dc_id, result.photo, result.currentSize = dc_id, photo, size
        result.photoPeer, result.photoPeerType, result.stickerSet = photoPeer, photoPeerType, stickerSet
        if isinstance(location, TLRPC.TL_fileLocationToBeDeprecated):
            result.location = location
            owner = photo if photo is not None else document
            if owner is not None:
                result.file_reference, result.access_hash, result.thumbSize = owner.file_reference, owner.access_hash, thumbSize
                if photo is not None:
                    result.photoId = photo.id
                else:
                    result.documentId = document.id
        else:
            result.location = TLRPC.TL_fileLocationToBeDeprecated()
            result.location.local_id, result.location.volume_id = location.local_id, location.volume_id
            result.location.secret = location.secret
            result.dc_id, result.file_reference = location.dc_id, location.file_reference
            result.key, result.iv, result.access_hash = location.key, location.iv, location.secret
        return result

    def isEncrypted(self):
        return self.key is not None

    def getSize(self):
        if self.photoSize is not None:
            return self.photoSize.size
        if self.secureDocument is not None:
            secure = self.secureDocument.secureFile
            return secure.size if secure is not None else self.currentSize
        if self.document is not None:
            return self.document.size
        if self.webFile is not None:
            return self.webFile.size
        return self.currentSize

    def _ayu_file_target(self):
        """The TL object ``FileLoader.loadFile(ImageLocation, …)`` hands to ``telegram.files.load``."""
        if self._source is not None:
            return self._source
        if self.document is not None and self.location is None:
            return self.document
        raise _m._unsupported("FileLoader cannot load this ImageLocation: the host resolves only a document or "
                              "a photo/document size")


CLASSES = _l.register({PACKAGE + "ImageLocation": ImageLocation})
