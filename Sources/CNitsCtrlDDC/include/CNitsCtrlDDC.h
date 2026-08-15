#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const CNDDCErrorDomain;

typedef NS_ENUM(NSInteger, CNDDCErrorCode) {
    CNDDCErrorUnsupported = 1,
    CNDDCErrorDiscoveryFailed = 2,
    CNDDCErrorDisplayUnavailable = 3,
    CNDDCErrorIOFailed = 4,
    CNDDCErrorMalformedReply = 5,
    CNDDCErrorVCPRejected = 6,
};

typedef struct {
    uint16_t current;
    uint16_t maximum;
} CNDDCVCPValue;

/// An external display backed by an Apple-silicon DCPAVServiceProxy.
///
/// The object owns the private IOKit service handle. Keep it alive for as long
/// as DDC transactions may be issued against the display.
@interface CNDDCDisplay : NSObject

@property(nonatomic, readonly, copy) NSData *edidData;
@property(nonatomic, readonly, copy) NSString *manufacturerID;
@property(nonatomic, readonly) uint16_t manufacturerCode;
@property(nonatomic, readonly) uint16_t productCode;
@property(nonatomic, readonly) uint32_t numericSerialNumber;
@property(nonatomic, readonly, copy, nullable) NSString *alphanumericSerialNumber;
@property(nonatomic, readonly, copy, nullable) NSString *productName;
@property(nonatomic, readonly) uint64_t registryEntryID;
@property(nonatomic, readonly, copy) NSString *registryPath;
@property(nonatomic, readonly) uint32_t chipAddress;
@property(nonatomic, readonly) BOOL edidIsValid;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

/// Discovers external Apple-silicon display proxy services.
///
/// An empty array is a successful result when no compatible display is
/// connected. A nil result means discovery itself was unavailable or failed.
FOUNDATION_EXPORT NSArray<CNDDCDisplay *> * _Nullable
CNDDCDiscoverExternalDisplays(NSError * _Nullable * _Nullable error);

/// Reads a VESA MCCS VCP feature. Brightness is feature code 0x10.
FOUNDATION_EXPORT BOOL
CNDDCReadVCP(CNDDCDisplay *display,
             uint8_t code,
             CNDDCVCPValue *value,
             NSError * _Nullable * _Nullable error);

/// Writes a VESA MCCS VCP feature. The protocol has no write acknowledgement;
/// callers that need certainty must read the value back.
FOUNDATION_EXPORT BOOL
CNDDCWriteVCP(CNDDCDisplay *display,
              uint8_t code,
              uint16_t value,
              NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
