#import "PDFPerformanceView.h"

@interface IAPDFDrawEvent ()
@property(nonatomic, readwrite) NSInteger pageIndex;
@property(nonatomic, readwrite) NSTimeInterval started;
@property(nonatomic, readwrite) NSTimeInterval finished;
@property(nonatomic, readwrite) BOOL onMainThread;
@end
@implementation IAPDFDrawEvent
@end

@interface IAPDFDrawSnapshot ()
@property(nonatomic, readwrite, copy) NSArray<IAPDFDrawEvent *> *events;
@property(nonatomic, readwrite) NSUInteger dropped;
@end
@implementation IAPDFDrawSnapshot
@end

@implementation IAPDFPerformanceView {
    NSLock *_drawLock;
    NSMapTable<PDFPage *, NSNumber *> *_pageIndices;
    NSMutableArray<IAPDFDrawEvent *> *_drawEvents;
    NSUInteger _dropped;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _drawLock = [[NSLock alloc] init];
        // Pointer identity avoids invoking PDFPage equality or metadata on a
        // render thread. Strong keys prevent identity reuse during the run.
        _pageIndices = [NSMapTable mapTableWithKeyOptions:
            NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality
            valueOptions:NSPointerFunctionsStrongMemory];
        _drawEvents = [[NSMutableArray alloc] init];
    }
    return self;
}

- (void)registerPage:(PDFPage *)page index:(NSInteger)index {
    [_drawLock lock];
    [_pageIndices setObject:@(index) forKey:page];
    [_drawLock unlock];
}

- (void)drawPage:(PDFPage *)page toContext:(CGContextRef)context {
    NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
    [super drawPage:page toContext:context];
    NSTimeInterval finished = NSProcessInfo.processInfo.systemUptime;
    BOOL onMainThread = NSThread.isMainThread;
    // Only Foundation timing/storage here: no Swift callback, page metadata,
    // UIKit mutation, XCTest access, or dispatch to the main queue.
    [_drawLock lock];
    if (_drawEvents.count < 10000) {
        IAPDFDrawEvent *event = [[IAPDFDrawEvent alloc] init];
        NSNumber *index = [_pageIndices objectForKey:page];
        event.pageIndex = index ? index.integerValue : -1;
        event.started = started;
        event.finished = finished;
        event.onMainThread = onMainThread;
        [_drawEvents addObject:event];
    } else {
        _dropped += 1;
    }
    [_drawLock unlock];
}

- (IAPDFDrawSnapshot *)drawSnapshot {
    IAPDFDrawSnapshot *snapshot = [[IAPDFDrawSnapshot alloc] init];
    [_drawLock lock];
    snapshot.events = _drawEvents;
    snapshot.dropped = _dropped;
    [_drawLock unlock];
    return snapshot;
}
@end
