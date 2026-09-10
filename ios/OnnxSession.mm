#import "OnnxSession.h"

#if __has_include(<onnxruntime/onnxruntime_cxx_api.h>)
#import <onnxruntime/onnxruntime_cxx_api.h>
#elif __has_include(<onnxruntime-c/onnxruntime_cxx_api.h>)
#import <onnxruntime-c/onnxruntime_cxx_api.h>
#else
#import "onnxruntime_cxx_api.h"
#endif

#include <memory>
#include <string>
#include <vector>

static NSString *const OnnxErrorDomain = @"com.nitrowakeword.onnx";

static NSError *OnnxMakeError(const std::string &message) {
  return [NSError errorWithDomain:OnnxErrorDomain
                             code:1
                         userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithUTF8String:message.c_str()]}];
}

@implementation OnnxTensor {
  NSData *_data;
  NSArray<NSNumber *> *_shape;
  BOOL _isInt64;
}

- (instancetype)initWithData:(NSData *)data shape:(NSArray<NSNumber *> *)shape isInt64:(BOOL)isInt64 {
  if (self = [super init]) {
    _data = data;
    _shape = shape;
    _isInt64 = isInt64;
  }
  return self;
}

+ (instancetype)floatTensorWithData:(NSData *)data shape:(NSArray<NSNumber *> *)shape {
  return [[OnnxTensor alloc] initWithData:data shape:shape isInt64:NO];
}

+ (instancetype)int64ScalarWithValue:(int64_t)value {
  return [[OnnxTensor alloc] initWithData:[NSData dataWithBytes:&value length:sizeof(int64_t)] shape:@[] isInt64:YES];
}

- (NSData *)data { return _data; }
- (NSArray<NSNumber *> *)shape { return _shape; }
- (BOOL)isInt64 { return _isInt64; }

@end

@implementation OnnxSession {
  std::unique_ptr<Ort::Env> _env;
  std::unique_ptr<Ort::Session> _session;
  std::vector<std::string> _inputNames;
  std::vector<std::string> _outputNames;
  NSArray<NSString *> *_inputNamesObjc;
  NSArray<NSString *> *_outputNamesObjc;
  NSArray<NSNumber *> *_firstInputShape;
}

- (nullable instancetype)initWithModelPath:(NSString *)path error:(NSError **)error {
  if (!(self = [super init])) return nil;
  try {
    _env = std::make_unique<Ort::Env>(ORT_LOGGING_LEVEL_WARNING, "NitroWakeWord");
    Ort::SessionOptions options;
    options.SetIntraOpNumThreads(1);
    options.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
    _session = std::make_unique<Ort::Session>(*_env, path.UTF8String, options);

    Ort::AllocatorWithDefaultOptions allocator;
    NSMutableArray<NSString *> *inputs = [NSMutableArray array];
    for (size_t i = 0; i < _session->GetInputCount(); i++) {
      auto name = _session->GetInputNameAllocated(i, allocator);
      _inputNames.emplace_back(name.get());
      [inputs addObject:[NSString stringWithUTF8String:name.get()]];
    }
    NSMutableArray<NSString *> *outputs = [NSMutableArray array];
    for (size_t i = 0; i < _session->GetOutputCount(); i++) {
      auto name = _session->GetOutputNameAllocated(i, allocator);
      _outputNames.emplace_back(name.get());
      [outputs addObject:[NSString stringWithUTF8String:name.get()]];
    }
    _inputNamesObjc = inputs;
    _outputNamesObjc = outputs;

    NSMutableArray<NSNumber *> *shape = [NSMutableArray array];
    if (_session->GetInputCount() > 0) {
      auto info = _session->GetInputTypeInfo(0).GetTensorTypeAndShapeInfo();
      for (int64_t dim : info.GetShape()) {
        [shape addObject:@(dim < 0 ? -1 : dim)];
      }
    }
    _firstInputShape = shape;
  } catch (const Ort::Exception &e) {
    if (error) *error = OnnxMakeError(e.what());
    return nil;
  } catch (const std::exception &e) {
    if (error) *error = OnnxMakeError(e.what());
    return nil;
  }
  return self;
}

- (NSArray<NSString *> *)inputNames { return _inputNamesObjc; }
- (NSArray<NSString *> *)outputNames { return _outputNamesObjc; }
- (NSArray<NSNumber *> *)firstInputShape { return _firstInputShape; }

- (nullable NSDictionary<NSString *, OnnxTensor *> *)run:(NSDictionary<NSString *, OnnxTensor *> *)inputs
                                                    error:(NSError **)error {
  try {
    Ort::MemoryInfo memoryInfo = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
    std::vector<const char *> inputNamePtrs;
    std::vector<Ort::Value> inputValues;
    inputNamePtrs.reserve(_inputNames.size());
    inputValues.reserve(_inputNames.size());

    for (const std::string &name : _inputNames) {
      OnnxTensor *tensor = inputs[[NSString stringWithUTF8String:name.c_str()]];
      if (tensor == nil) {
        if (error) *error = OnnxMakeError("Missing input tensor: " + name);
        return nil;
      }
      std::vector<int64_t> shape;
      for (NSNumber *dim in tensor.shape) shape.push_back(dim.longLongValue);
      inputNamePtrs.push_back(name.c_str());
      if (tensor.isInt64) {
        inputValues.push_back(Ort::Value::CreateTensor<int64_t>(
            memoryInfo, (int64_t *)tensor.data.bytes, tensor.data.length / sizeof(int64_t), shape.data(), shape.size()));
      } else {
        inputValues.push_back(Ort::Value::CreateTensor<float>(
            memoryInfo, (float *)tensor.data.bytes, tensor.data.length / sizeof(float), shape.data(), shape.size()));
      }
    }

    std::vector<const char *> outputNamePtrs;
    for (const std::string &name : _outputNames) outputNamePtrs.push_back(name.c_str());

    std::vector<Ort::Value> outputs = _session->Run(Ort::RunOptions{nullptr}, inputNamePtrs.data(), inputValues.data(),
                                                    inputValues.size(), outputNamePtrs.data(), outputNamePtrs.size());

    NSMutableDictionary<NSString *, OnnxTensor *> *result = [NSMutableDictionary dictionary];
    for (size_t i = 0; i < outputs.size(); i++) {
      auto info = outputs[i].GetTensorTypeAndShapeInfo();
      NSMutableArray<NSNumber *> *shape = [NSMutableArray array];
      for (int64_t dim : info.GetShape()) [shape addObject:@(dim)];
      size_t count = info.GetElementCount();
      const float *floats = outputs[i].GetTensorData<float>();
      NSData *data = [NSData dataWithBytes:floats length:count * sizeof(float)];
      result[[NSString stringWithUTF8String:_outputNames[i].c_str()]] = [OnnxTensor floatTensorWithData:data shape:shape];
    }
    return result;
  } catch (const Ort::Exception &e) {
    if (error) *error = OnnxMakeError(e.what());
    return nil;
  } catch (const std::exception &e) {
    if (error) *error = OnnxMakeError(e.what());
    return nil;
  }
}

@end
