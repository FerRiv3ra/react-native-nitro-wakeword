#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A tensor handed to / returned from `OnnxSession`. Float32 or int64 data.
@interface OnnxTensor : NSObject
@property (nonatomic, readonly) NSData *data;
@property (nonatomic, readonly) NSArray<NSNumber *> *shape;
@property (nonatomic, readonly) BOOL isInt64;
+ (instancetype)floatTensorWithData:(NSData *)data shape:(NSArray<NSNumber *> *)shape NS_SWIFT_NAME(floatTensor(_:shape:));
+ (instancetype)int64ScalarWithValue:(int64_t)value NS_SWIFT_NAME(int64Scalar(_:));
- (instancetype)init NS_UNAVAILABLE;
@end

/// Minimal Objective-C++ wrapper over the ONNX Runtime C++ API so that Swift can
/// use ONNX Runtime from a static-library pod without `use_modular_headers!`.
@interface OnnxSession : NSObject
@property (nonatomic, readonly) NSArray<NSString *> *inputNames;
@property (nonatomic, readonly) NSArray<NSString *> *outputNames;
/// Declared shape of the first input. Symbolic dimensions are reported as -1.
@property (nonatomic, readonly) NSArray<NSNumber *> *firstInputShape;

- (nullable instancetype)initWithModelPath:(NSString *)path error:(NSError **)error;
- (instancetype)init NS_UNAVAILABLE;

/// Runs the model. Every output is returned as a float32 tensor.
- (nullable NSDictionary<NSString *, OnnxTensor *> *)run:(NSDictionary<NSString *, OnnxTensor *> *)inputs
                                                    error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
