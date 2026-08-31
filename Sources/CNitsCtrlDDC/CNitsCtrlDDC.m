#import "CNitsCtrlDDC.h"

#import <dispatch/dispatch.h>
#import <IOKit/IOKitLib.h>
#import <string.h>
#import <unistd.h>

/*
 * The IOAVService functions below are unheadered IOKit SPI on Apple silicon.
 * They are weak-linked so discovery fails cleanly if Apple removes them.
 *
 * The DDC framing and DCPAVServiceProxy approach are adapted from the
 * MIT-licensed m1ddc, AppleSiliconDDC, and MonitorControl projects. See
 * THIRD_PARTY_NOTICES.md for attribution and source links.
 */
typedef CFTypeRef IOAVServiceRef;

extern IOAVServiceRef _Nullable
IOAVServiceCreateWithService(CFAllocatorRef _Nullable allocator,
                             io_service_t service)
    __attribute__((weak_import));

extern IOReturn
IOAVServiceCopyEDID(IOAVServiceRef service, CFDataRef _Nullable * _Nonnull edid)
    __attribute__((weak_import));

extern IOReturn
IOAVServiceReadI2C(IOAVServiceRef service,
                   uint32_t chipAddress,
                   uint32_t dataAddress,
                   void *buffer,
                   uint32_t length)
    __attribute__((weak_import));

extern IOReturn
IOAVServiceWriteI2C(IOAVServiceRef service,
                    uint32_t chipAddress,
                    uint32_t dataAddress,
                    const void *buffer,
                    uint32_t length)
    __attribute__((weak_import));

NSErrorDomain const CNDDCErrorDomain = @"app.nits-sync.ddc";

static const uint32_t CNDDCDisplayPortChipAddress = 0x37;
static const uint32_t CNDDCMCDP29XXChipAddress = 0xb7;
static const uint32_t CNDDCCommandAddress = 0x51;
static const uint8_t CNDDCHostAddress = 0x50;
static const uint8_t CNDDCDisplayAddress = 0x6e;
// IOAVServiceCopyEDID can remain blocked after its display is unplugged while
// macOS is rebuilding DCP services. Never let one stale proxy stop discovery
// of the displays that are still connected.
static const int64_t CNDDCEDIDCopyTimeoutNanoseconds = 2 * NSEC_PER_SEC;

@interface CNDDCDisplay ()

@property(nonatomic, assign) IOAVServiceRef avService;
@property(nonatomic, readwrite, copy) NSData *edidData;
@property(nonatomic, readwrite, copy) NSString *manufacturerID;
@property(nonatomic, readwrite) uint16_t manufacturerCode;
@property(nonatomic, readwrite) uint16_t productCode;
@property(nonatomic, readwrite) uint32_t numericSerialNumber;
@property(nonatomic, readwrite, copy, nullable) NSString *alphanumericSerialNumber;
@property(nonatomic, readwrite, copy, nullable) NSString *productName;
@property(nonatomic, readwrite) uint64_t registryEntryID;
@property(nonatomic, readwrite, copy) NSString *registryPath;
@property(nonatomic, readwrite) uint32_t chipAddress;
@property(nonatomic, readwrite) BOOL edidIsValid;

- (instancetype)initWithAVService:(IOAVServiceRef)avService
                          edidData:(NSData *)edidData
                   registryEntryID:(uint64_t)registryEntryID
                     registryPath:(NSString *)registryPath
                      chipAddress:(uint32_t)chipAddress;

@end

static NSError *CNDDCMakeError(CNDDCErrorCode code, NSString *description) {
    return [NSError errorWithDomain:CNDDCErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

static NSError *CNDDCMakeIOError(NSString *operation, IOReturn result) {
    NSString *description = [NSString stringWithFormat:
        @"%@ failed (IOKit status 0x%08x).", operation, result];
    return CNDDCMakeError(CNDDCErrorIOFailed, description);
}

static NSLock *CNDDCEDIDReadLock(void) {
    static NSLock *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lock = [[NSLock alloc] init];
    });
    return lock;
}

static NSMutableSet<NSNumber *> *CNDDCEDIDReadsInFlight(void) {
    static NSMutableSet<NSNumber *> *entryIDs;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        entryIDs = [NSMutableSet set];
    });
    return entryIDs;
}

/// Reserves one EDID request per registry entry. A request that times out may
/// still be stuck inside the unheadered macOS API, so later discoveries skip
/// that entry instead of accumulating blocked worker threads. The worker
/// releases the reservation if the system call eventually returns.
static BOOL CNDDCBeginEDIDRead(uint64_t registryEntryID) {
    NSNumber *entryID = @(registryEntryID);
    NSLock *lock = CNDDCEDIDReadLock();
    [lock lock];
    BOOL canBegin = ![CNDDCEDIDReadsInFlight() containsObject:entryID];
    if (canBegin) {
        [CNDDCEDIDReadsInFlight() addObject:entryID];
    }
    [lock unlock];
    return canBegin;
}

static void CNDDCEndEDIDRead(uint64_t registryEntryID) {
    NSLock *lock = CNDDCEDIDReadLock();
    [lock lock];
    [CNDDCEDIDReadsInFlight() removeObject:@(registryEntryID)];
    [lock unlock];
}

static NSData *CNDDCCopyEDIDWithTimeout(IOAVServiceRef avService,
                                        uint64_t registryEntryID,
                                        BOOL *timedOut) {
    if (timedOut != NULL) {
        *timedOut = NO;
    }
    if (!CNDDCBeginEDIDRead(registryEntryID)) {
        if (timedOut != NULL) {
            *timedOut = YES;
        }
        return nil;
    }

    dispatch_group_t group = dispatch_group_create();
    __block NSData *edidData = [NSData data];

    // The discovery loop owns its reference only until this helper returns.
    // Keep a separate reference alive if the system call outlives the timeout.
    CFRetain(avService);
    dispatch_group_async(
        group,
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
        ^{
            @autoreleasepool {
                CFDataRef copiedEDID = NULL;
                IOReturn result = IOAVServiceCopyEDID(avService, &copiedEDID);
                if (result == kIOReturnSuccess && copiedEDID != NULL) {
                    edidData = [(__bridge NSData *)copiedEDID copy];
                }
                if (copiedEDID != NULL) {
                    CFRelease(copiedEDID);
                }
                CNDDCEndEDIDRead(registryEntryID);
                CFRelease(avService);
            }
        });

    long waitResult = dispatch_group_wait(
        group,
        dispatch_time(DISPATCH_TIME_NOW, CNDDCEDIDCopyTimeoutNanoseconds));
    if (waitResult != 0) {
        if (timedOut != NULL) {
            *timedOut = YES;
        }
        return nil;
    }
    return edidData;
}

static void CNDDCAssignError(NSError **destination, NSError *error) {
    if (destination != NULL) {
        *destination = error;
    }
}

static NSString *CNDDCStringProperty(io_service_t service, CFStringRef key) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(
        service, key, kCFAllocatorDefault, 0);
    if (value == NULL) {
        return nil;
    }

    NSString *result = nil;
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        result = [(__bridge NSString *)value copy];
    }
    CFRelease(value);
    return result;
}

/// HDMI-family MCDP29XX controllers use a controller-specific I2C selector.
/// The DDC packet itself still contains the standard 0x6e display address.
static uint32_t CNDDCChipAddressForService(io_service_t service) {
    io_registry_entry_t cursor = service;
    BOOL cursorMustBeReleased = NO;

    while (cursor != IO_OBJECT_NULL) {
        BOOL matches = IOObjectConformsTo(cursor, "AppleDCPMCDP29XX");
        if (!matches) {
            io_name_t name = {0};
            if (IORegistryEntryGetName(cursor, name) == kIOReturnSuccess) {
                matches = strstr(name, "AppleDCPMCDP29XX") != NULL;
            }
        }

        if (matches) {
            if (cursorMustBeReleased) {
                IOObjectRelease(cursor);
            }
            return CNDDCMCDP29XXChipAddress;
        }

        io_registry_entry_t parent = IO_OBJECT_NULL;
        IOReturn result = IORegistryEntryGetParentEntry(
            cursor, kIOServicePlane, &parent);
        if (cursorMustBeReleased) {
            IOObjectRelease(cursor);
        }
        if (result != kIOReturnSuccess) {
            break;
        }
        cursor = parent;
        cursorMustBeReleased = YES;
    }

    return CNDDCDisplayPortChipAddress;
}

static BOOL CNDDCValidateEDID(NSData *data) {
    if (data.length < 128 || data.length % 128 != 0) {
        return NO;
    }

    const uint8_t *bytes = data.bytes;
    static const uint8_t header[] = {0x00, 0xff, 0xff, 0xff,
                                     0xff, 0xff, 0xff, 0x00};
    if (memcmp(bytes, header, sizeof(header)) != 0) {
        return NO;
    }

    NSUInteger requiredBlocks = (NSUInteger)bytes[126] + 1;
    if (data.length < requiredBlocks * 128) {
        return NO;
    }

    for (NSUInteger block = 0; block < requiredBlocks; block++) {
        uint8_t checksum = 0;
        for (NSUInteger index = 0; index < 128; index++) {
            checksum = (uint8_t)(checksum + bytes[block * 128 + index]);
        }
        if (checksum != 0) {
            return NO;
        }
    }
    return YES;
}

static NSString *CNDDCManufacturerID(uint16_t code) {
    uint8_t first = (uint8_t)((code >> 10) & 0x1f);
    uint8_t second = (uint8_t)((code >> 5) & 0x1f);
    uint8_t third = (uint8_t)(code & 0x1f);
    if (first < 1 || first > 26 || second < 1 || second > 26 ||
        third < 1 || third > 26) {
        return @"UNK";
    }

    unichar characters[] = {
        (unichar)('A' + first - 1),
        (unichar)('A' + second - 1),
        (unichar)('A' + third - 1),
    };
    return [NSString stringWithCharacters:characters length:3];
}

static NSString *CNDDCDescriptorText(const uint8_t *baseBlock, uint8_t tag) {
    static const NSUInteger offsets[] = {54, 72, 90, 108};
    for (NSUInteger descriptor = 0;
         descriptor < sizeof(offsets) / sizeof(offsets[0]);
         descriptor++) {
        const uint8_t *bytes = baseBlock + offsets[descriptor];
        if (bytes[0] != 0 || bytes[1] != 0 || bytes[3] != tag) {
            continue;
        }

        NSData *textData = [NSData dataWithBytes:bytes + 5 length:13];
        NSString *text = [[NSString alloc] initWithData:textData
                                                encoding:NSASCIIStringEncoding];
        if (text == nil) {
            continue;
        }

        NSCharacterSet *padding = [NSCharacterSet characterSetWithCharactersInString:
            @"\0\n\r \t"];
        text = [text stringByTrimmingCharactersInSet:padding];
        if (text.length > 0) {
            return text;
        }
    }
    return nil;
}

@implementation CNDDCDisplay

- (instancetype)initWithAVService:(IOAVServiceRef)avService
                          edidData:(NSData *)edidData
                   registryEntryID:(uint64_t)registryEntryID
                     registryPath:(NSString *)registryPath
                      chipAddress:(uint32_t)chipAddress {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    _avService = avService;
    _edidData = [edidData copy];
    _registryEntryID = registryEntryID;
    _registryPath = [registryPath copy];
    _chipAddress = chipAddress;
    _manufacturerID = @"UNK";

    if (edidData.length >= 128) {
        const uint8_t *bytes = edidData.bytes;
        _manufacturerCode = (uint16_t)(((uint16_t)bytes[8] << 8) | bytes[9]);
        _manufacturerID = [CNDDCManufacturerID(_manufacturerCode) copy];
        _productCode = (uint16_t)((uint16_t)bytes[10] |
                                  ((uint16_t)bytes[11] << 8));
        _numericSerialNumber = (uint32_t)bytes[12] |
                               ((uint32_t)bytes[13] << 8) |
                               ((uint32_t)bytes[14] << 16) |
                               ((uint32_t)bytes[15] << 24);
        _productName = [CNDDCDescriptorText(bytes, 0xfc) copy];
        _alphanumericSerialNumber = [CNDDCDescriptorText(bytes, 0xff) copy];
    }

    _edidIsValid = CNDDCValidateEDID(edidData);
    return self;
}

- (void)dealloc {
    if (_avService != NULL) {
        CFRelease(_avService);
        _avService = NULL;
    }
}

@end

NSArray<CNDDCDisplay *> *CNDDCDiscoverExternalDisplays(NSError **error) {
    if (IOAVServiceCreateWithService == NULL ||
        IOAVServiceReadI2C == NULL ||
        IOAVServiceWriteI2C == NULL) {
        CNDDCAssignError(error, CNDDCMakeError(
            CNDDCErrorUnsupported,
            @"This macOS version does not expose Apple-silicon display I/O."));
        return nil;
    }

    io_registry_entry_t root = IORegistryGetRootEntry(kIOMainPortDefault);
    if (root == IO_OBJECT_NULL) {
        CNDDCAssignError(error, CNDDCMakeError(
            CNDDCErrorDiscoveryFailed,
            @"Could not open the I/O Registry."));
        return nil;
    }

    io_iterator_t iterator = IO_OBJECT_NULL;
    IOReturn result = IORegistryEntryCreateIterator(
        root, kIOServicePlane, kIORegistryIterateRecursively, &iterator);
    if (result != kIOReturnSuccess) {
        IOObjectRelease(root);
        CNDDCAssignError(error, CNDDCMakeIOError(
            @"External display discovery", result));
        return nil;
    }

    NSMutableArray<CNDDCDisplay *> *displays = [NSMutableArray array];
    NSUInteger externalProxyCount = 0;
    io_service_t service = IO_OBJECT_NULL;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        @autoreleasepool {
            io_name_t serviceName = {0};
            if (IORegistryEntryGetName(service, serviceName) !=
                    kIOReturnSuccess ||
                strcmp(serviceName, "DCPAVServiceProxy") != 0) {
                IOObjectRelease(service);
                continue;
            }

            NSString *location = CNDDCStringProperty(service, CFSTR("Location"));
            if (location == nil ||
                [location caseInsensitiveCompare:@"External"] != NSOrderedSame) {
                IOObjectRelease(service);
                continue;
            }
            externalProxyCount += 1;

            uint64_t entryID = 0;
            (void)IORegistryEntryGetRegistryEntryID(service, &entryID);

            IOAVServiceRef avService = IOAVServiceCreateWithService(
                kCFAllocatorDefault, service);
            if (avService == NULL) {
                IOObjectRelease(service);
                continue;
            }

            NSData *edidData = [NSData data];
            if (IOAVServiceCopyEDID != NULL) {
                BOOL edidTimedOut = NO;
                NSData *copiedEDID = CNDDCCopyEDIDWithTimeout(
                    avService, entryID, &edidTimedOut);
                if (edidTimedOut) {
                    CFRelease(avService);
                    IOObjectRelease(service);
                    continue;
                }
                if (copiedEDID != nil) {
                    edidData = copiedEDID;
                }
            }

            io_string_t pathBuffer = {0};
            NSString *registryPath = @"";
            if (IORegistryEntryGetPath(service, kIOServicePlane, pathBuffer) ==
                kIOReturnSuccess) {
                NSString *path = [NSString stringWithUTF8String:pathBuffer];
                registryPath = path != nil ? path : @"";
            }

            CNDDCDisplay *display = [[CNDDCDisplay alloc]
                initWithAVService:avService
                         edidData:edidData
                  registryEntryID:entryID
                    registryPath:registryPath
                     chipAddress:CNDDCChipAddressForService(service)];
            if (display != nil) {
                [displays addObject:display];
            } else {
                CFRelease(avService);
            }
            IOObjectRelease(service);
        }
    }
    IOObjectRelease(iterator);
    IOObjectRelease(root);

    if (externalProxyCount > 0 && displays.count == 0) {
        CNDDCAssignError(error, CNDDCMakeError(
            CNDDCErrorDisplayUnavailable,
            @"macOS exposed an external display proxy, but its I/O service did not become ready."));
        return nil;
    }

    [displays sortUsingComparator:^NSComparisonResult(
        CNDDCDisplay *left, CNDDCDisplay *right) {
        NSComparisonResult manufacturer = [left.manufacturerID
            compare:right.manufacturerID options:NSCaseInsensitiveSearch];
        if (manufacturer != NSOrderedSame) {
            return manufacturer;
        }
        if (left.productCode != right.productCode) {
            return left.productCode < right.productCode
                ? NSOrderedAscending : NSOrderedDescending;
        }
        if (left.numericSerialNumber != right.numericSerialNumber) {
            return left.numericSerialNumber < right.numericSerialNumber
                ? NSOrderedAscending : NSOrderedDescending;
        }
        return [left.registryPath compare:right.registryPath];
    }];
    return displays;
}

static NSLock *CNDDCOperationLock(void) {
    static NSLock *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lock = [[NSLock alloc] init];
    });
    return lock;
}

static void CNDDCBuildGetRequest(uint8_t code, uint8_t request[4]) {
    request[0] = 0x82;
    request[1] = 0x01;
    request[2] = code;
    request[3] = (uint8_t)(CNDDCDisplayAddress ^ request[0] ^
                           request[1] ^ request[2]);
}

static BOOL CNDDCValidateGetReply(const uint8_t reply[11],
                                  uint8_t code,
                                  CNDDCVCPValue *value,
                                  NSError **error) {
    if (reply[0] != CNDDCDisplayAddress || reply[1] != 0x88 ||
        reply[2] != 0x02) {
        CNDDCAssignError(error, CNDDCMakeError(
            CNDDCErrorMalformedReply,
            [NSString stringWithFormat:
                @"The monitor returned a malformed DDC reply header "
                 "(%02x %02x %02x).",
                reply[0], reply[1], reply[2]]));
        return NO;
    }

    uint8_t checksum = CNDDCHostAddress;
    for (NSUInteger index = 0; index < 10; index++) {
        checksum ^= reply[index];
    }
    if (checksum != reply[10]) {
        CNDDCAssignError(error, CNDDCMakeError(
            CNDDCErrorMalformedReply,
            @"The monitor returned a DDC reply with an invalid checksum."));
        return NO;
    }
    if (reply[3] != 0) {
        CNDDCAssignError(error, CNDDCMakeError(
            CNDDCErrorVCPRejected,
            @"The monitor reported that the requested VCP feature is unsupported."));
        return NO;
    }
    if (reply[4] != code) {
        CNDDCAssignError(error, CNDDCMakeError(
            CNDDCErrorMalformedReply,
            @"The monitor replied with a different VCP feature code."));
        return NO;
    }

    value->maximum = (uint16_t)(((uint16_t)reply[6] << 8) | reply[7]);
    value->current = (uint16_t)(((uint16_t)reply[8] << 8) | reply[9]);
    return YES;
}

static BOOL CNDDCIssueGetRequest(IOAVServiceRef service,
                                 uint32_t chipAddress,
                                 uint8_t code,
                                 uint32_t readAddress,
                                 CNDDCVCPValue *value,
                                 NSError **error) {
    uint8_t request[4];
    CNDDCBuildGetRequest(code, request);

    IOReturn firstWrite = IOAVServiceWriteI2C(
        service, chipAddress, CNDDCCommandAddress,
        request, (uint32_t)sizeof(request));
    usleep(10 * 1000);
    IOReturn secondWrite = IOAVServiceWriteI2C(
        service, chipAddress, CNDDCCommandAddress,
        request, (uint32_t)sizeof(request));
    if (firstWrite != kIOReturnSuccess && secondWrite != kIOReturnSuccess) {
        CNDDCAssignError(error, CNDDCMakeIOError(@"DDC request", secondWrite));
        return NO;
    }

    usleep(50 * 1000);
    uint8_t reply[11] = {0};
    IOReturn readResult = IOAVServiceReadI2C(
        service, chipAddress, readAddress,
        reply, (uint32_t)sizeof(reply));
    if (readResult != kIOReturnSuccess) {
        CNDDCAssignError(error, CNDDCMakeIOError(@"DDC reply", readResult));
        return NO;
    }
    return CNDDCValidateGetReply(reply, code, value, error);
}

BOOL CNDDCReadVCP(CNDDCDisplay *display,
                  uint8_t code,
                  CNDDCVCPValue *value,
                  NSError **error) {
    if (display == nil || display.avService == NULL || value == NULL) {
        CNDDCAssignError(error, CNDDCMakeError(
            CNDDCErrorDisplayUnavailable,
            @"The external display is no longer available."));
        return NO;
    }

    NSLock *lock = CNDDCOperationLock();
    [lock lock];
    @try {
        NSError *firstError = nil;
        if (CNDDCIssueGetRequest(
                display.avService, display.chipAddress, code,
                CNDDCCommandAddress,
                value, &firstError)) {
            return YES;
        }

        NSError *fallbackError = nil;
        if (CNDDCIssueGetRequest(
                display.avService, display.chipAddress, code, 0,
                value, &fallbackError)) {
            return YES;
        }
        CNDDCAssignError(error,
                         fallbackError != nil ? fallbackError : firstError);
        return NO;
    } @finally {
        [lock unlock];
    }
}

static void CNDDCBuildSetRequest(uint8_t code,
                                 uint16_t value,
                                 uint8_t request[6]) {
    request[0] = 0x84;
    request[1] = 0x03;
    request[2] = code;
    request[3] = (uint8_t)(value >> 8);
    request[4] = (uint8_t)(value & 0xff);
    request[5] = (uint8_t)(CNDDCDisplayAddress ^ CNDDCCommandAddress ^
                           request[0] ^ request[1] ^ request[2] ^
                           request[3] ^ request[4]);
}

BOOL CNDDCWriteVCP(CNDDCDisplay *display,
                   uint8_t code,
                   uint16_t value,
                   NSError **error) {
    if (display == nil || display.avService == NULL) {
        CNDDCAssignError(error, CNDDCMakeError(
            CNDDCErrorDisplayUnavailable,
            @"The external display is no longer available."));
        return NO;
    }

    uint8_t request[6];
    CNDDCBuildSetRequest(code, value, request);

    NSLock *lock = CNDDCOperationLock();
    [lock lock];
    @try {
        IOReturn firstWrite = IOAVServiceWriteI2C(
            display.avService, display.chipAddress, CNDDCCommandAddress,
            request, (uint32_t)sizeof(request));
        usleep(10 * 1000);
        IOReturn secondWrite = IOAVServiceWriteI2C(
            display.avService, display.chipAddress, CNDDCCommandAddress,
            request, (uint32_t)sizeof(request));
        if (firstWrite != kIOReturnSuccess && secondWrite != kIOReturnSuccess) {
            CNDDCAssignError(error, CNDDCMakeIOError(
                @"DDC brightness write", secondWrite));
            return NO;
        }
        return YES;
    } @finally {
        [lock unlock];
    }
}
