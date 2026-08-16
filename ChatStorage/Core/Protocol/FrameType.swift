import Foundation

enum FrameType: UInt8, CaseIterable, Sendable {
    case metadata = 0x01
    case data = 0x02
    case end = 0x03
    case acknowledgement = 0x04
    case resumeCheck = 0x05
    case resumeAcknowledgement = 0x06

    case directoryCreateRequest = 0x10
    case directoryDeleteRequest = 0x11
    case directoryUpdateRequest = 0x12
    case directoryMoveRequest = 0x13
    case directoryResponse = 0x14
    case directoryListRequest = 0x15

    case directoryFileMetadata = 0x20
    case directoryFileData = 0x21
    case directoryFileEnd = 0x22
    case directoryFileAcknowledgement = 0x23

    case userRegisterRequest = 0x30
    case userLoginRequest = 0x31
    case userChangePasswordRequest = 0x32
    case userLogoutRequest = 0x33
    case userResponse = 0x34
    case friendListRequest = 0x35
    case friendSearchRequest = 0x36
    case friendAddRequest = 0x37
    case friendRequestsRequest = 0x38
    case friendHandleRequest = 0x39
    case friendSearchResponse = 0x3A
    case friendAddResponse = 0x3B
    case friendRequestsResponse = 0x3C
    case friendHandleResponse = 0x3D
    case friendEventPush = 0x3E
    case friendListResponse = 0x3F

    case fileListRequest = 0x40
    case fileDeleteRequest = 0x41
    case fileDetailRequest = 0x42
    case fileResponse = 0x43
    case fileRenameRequest = 0x44
    case userAvatarUpdateRequest = 0x45
    case userSessionResumeRequest = 0x46
    case heartbeatRequest = 0x47
    case heartbeatResponse = 0x48

    case chatSendRequest = 0x50
    case chatPush = 0x51
    case chatReceipt = 0x52
    case chatHistoryRequest = 0x53
    case chatHistoryResponse = 0x54
    case chatReadRequest = 0x55
    case chatReadResponse = 0x56
    case friendAliasUpdateRequest = 0x57
    case friendAliasUpdateResponse = 0x58
    case chatMessageActionRequest = 0x59
    case chatMessageActionResponse = 0x5A
    case chatMessageActionPush = 0x5B
    case friendPinUpdateRequest = 0x5C
    case friendPinUpdateResponse = 0x5D
    case chatMessageSearchRequest = 0x5E
    case chatMessageSearchResponse = 0x5F

    case dynamicCreateRequest = 0x60
    case dynamicCreateResponse = 0x61
    case dynamicTimelineRequest = 0x62
    case dynamicTimelineResponse = 0x63
    case dynamicActionRequest = 0x64
    case dynamicActionResponse = 0x65
    case dynamicDetailRequest = 0x66
    case dynamicDetailResponse = 0x67
    case dynamicDeleteRequest = 0x68
    case dynamicDeleteResponse = 0x69

    // [修改] 保留旧调用点名称，0x61 仍是发布动态回执。
    static var dynamicResponse: FrameType { .dynamicCreateResponse }
}
