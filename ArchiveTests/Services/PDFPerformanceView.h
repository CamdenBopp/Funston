#import <PDFKit/PDFKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Immutable values copied out of the locked, test-only native draw recorder.
@interface IAPDFDrawEvent : NSObject
@property(nonatomic, readonly) NSInteger pageIndex;
@property(nonatomic, readonly) NSTimeInterval started;
@property(nonatomic, readonly) NSTimeInterval finished;
@property(nonatomic, readonly) BOOL onMainThread;
@end

@interface IAPDFDrawSnapshot : NSObject
@property(nonatomic, readonly, copy) NSArray<IAPDFDrawEvent *> *events;
@property(nonatomic, readonly) NSUInteger dropped;
@end

/// Objective-C deliberately owns the override: PDFKit invokes it on tile worker
/// threads, which must not enter a Swift UIKit subclass's MainActor thunk.
@interface IAPDFPerformanceView : PDFView
- (void)registerPage:(PDFPage *)page index:(NSInteger)index NS_SWIFT_NAME(register(page:index:));
- (IAPDFDrawSnapshot *)drawSnapshot NS_SWIFT_NAME(drawSnapshot());
@end

NS_ASSUME_NONNULL_END
