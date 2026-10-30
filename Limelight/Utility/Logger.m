//
//  Logger.m
//  Moonlight
//
//  Created by Diego Waxemberg on 2/10/15.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "Logger.h"

static LogLevel LoggerLogLevel = LOG_I;

void LogTagv(LogLevel level, NSString* tag, NSString* fmt, va_list args);
static void LogToFile(NSString *line);

void Log(LogLevel level, NSString* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    LogTagv(level, NULL, fmt, args);
    va_end(args);
}

void LogTag(LogLevel level, NSString* tag, NSString* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    LogTagv(level, tag, fmt, args);
    va_end(args);
}

void LogTagv(LogLevel level, NSString* tag, NSString* fmt, va_list args) {
    NSString* levelPrefix = @"";
    
    if (level < LoggerLogLevel) {
        return;
    }
    
    switch(level) {
        case LOG_D:
            levelPrefix = PRFX_DEBUG;
            break;
        case LOG_I:
            levelPrefix = PRFX_INFO;
            break;
        case LOG_W:
            levelPrefix = PRFX_WARN;
            break;
        case LOG_E:
            levelPrefix = PRFX_ERROR;
            break;
        default:
            levelPrefix = @"";
            assert(false);
            break;
    }
    NSString* prefixedString;
    if (tag) {
        prefixedString = [NSString stringWithFormat:@"%@ (%@) %@", levelPrefix, tag, fmt];
    } else {
        prefixedString = [NSString stringWithFormat:@"%@ %@", levelPrefix, fmt];
    }
    va_list copy;
    va_copy(copy, args);
    NSLogv(prefixedString, args);
    LogToFile([[NSString alloc] initWithFormat:prefixedString arguments:copy]);
    va_end(copy);
}

// The same lines in Library/Caches/traceport.log (rotated at 512 KB to traceport.log.1), so a
// problem seen on a device far away can be read afterwards: `devicectl device copy from
// --domain-type appDataContainer --domain-identifier io.traceone.port --source
// Library/Caches/traceport.log`. NSLog alone needs a cable or a tunnel at the moment it happens.
static void LogToFile(NSString *line) {
    static dispatch_queue_t queue;
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("traceport.log", DISPATCH_QUEUE_SERIAL);
        NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        path = [caches stringByAppendingPathComponent:@"traceport.log"];
    });
    static NSDateFormatter *fmt;
    NSString *stamp;
    @synchronized (path) {
        if (fmt == nil) {
            fmt = [[NSDateFormatter alloc] init];
            fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
        }
        stamp = [fmt stringFromDate:[NSDate date]];
    }
    NSData *data = [[NSString stringWithFormat:@"%@ %@\n", stamp, line] dataUsingEncoding:NSUTF8StringEncoding];
    dispatch_async(queue, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
        if ([attrs fileSize] > 512 * 1024) {
            NSString *old = [path stringByAppendingString:@".1"];
            [fm removeItemAtPath:old error:nil];
            [fm moveItemAtPath:path toPath:old error:nil];
        }
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
        if (h == nil) {
            [data writeToFile:path atomically:NO];
            return;
        }
        [h seekToEndOfFile];
        [h writeData:data];
        [h closeFile];
    });
}
