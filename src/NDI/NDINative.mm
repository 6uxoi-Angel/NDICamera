#import "NDINative.h"

// ---- NDI SDK (v5/v6) ----
// Заголовки SDK лежат в NDISDK/include (см. README)
#import <Processing.NDI.Lib.h>
#import <Processing.NDI.Structs.h>

#import <pthread.h>

@implementation NDINative {
    NDIlib_send_instance_t _sender;
    NDIlib_recv_instance_t _tallyRecv;
    BOOL _open;
    dispatch_queue_t _sendQueue;
    NSString *_sourceName;
    NSString *_lastErrorMessage;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _sendQueue = dispatch_queue_create("ndi.native.send", DISPATCH_QUEUE_SERIAL);
        _open = NO;
        _sender = NULL;
        _tallyRecv = NULL;
        _lastErrorMessage = @"";
    }
    return self;
}

- (NSString*)lastErrorMessage { return _lastErrorMessage; }

- (BOOL)openWithName:(NSString*)name
              targetIP:(NSString*)targetIP
       discoveryServer:(NSString*)discoveryServer
               localIP:(NSString*)localIP {
    if (_open) return YES;

    if (!NDIlib_initialize()) {
        _lastErrorMessage = @"NDIlib_initialize() вернул false (лицензия/архитектура)";
        return NO;
    }

    _sourceName = [name copy];

    NDIlib_send_create_t create;
    memset(&create, 0, sizeof(create));
    create.p_ndi_name = (const char*)[name UTF8String];
    create.clock_video = true;
    create.clock_audio = true;
    // Выбор локального интерфейса (USB Remote NDIS / Wi-Fi)
    if (localIP.length > 0) {
        create.p_ip_address = (const char*)[localIP UTF8String];
    }

    _sender = NDIlib_send_create(&create);
    if (!_sender) {
        _lastErrorMessage = @"NDIlib_send_create() не удался";
        return NO;
    }

    // Discovery Server (fallback для mDNS)
    if (discoveryServer.length > 0) {
        NDIlib_discovery_create_t dc;
        memset(&dc, 0, sizeof(dc));
        dc.p_ndi_name = (const char*)[discoveryServer UTF8String];
        NDIlib_discovery_instance_t disc = NDIlib_discovery_create(&dc);
        if (disc) NDIlib_discovery_destroy(disc);
    }

    // Обратный канал для tally (метаданные из DistroAV/OBS)
    NDIlib_recv_create_v3_t rc;
    memset(&rc, 0, sizeof(rc));
    rc.source_name = (const char*)[name UTF8String];
    rc.color_format = NDIlib_recv_color_format_bgrx_bgra;
    rc.bandwidth = NDIlib_recv_bandwidth_lowest; // метаданные — максимум
    rc.allow_video_fields = true;
    _tallyRecv = NDIlib_recv_create_v3(&rc);

    _lastErrorMessage = @"";
    _open = YES;
    return YES;
}

- (void)close {
    if (_tallyRecv) { NDIlib_recv_destroy(_tallyRecv); _tallyRecv = NULL; }
    if (_sender) { NDIlib_send_destroy(_sender); _sender = NULL; }
    _open = NO;
    NDIlib_destroy();
}

- (BOOL)isOpen { return _open; }

- (void)sendVideoH264:(NSData*)payload
                 width:(int)width
                height:(int)height
             timestampUs:(int64_t)timestampUs
              keyFrame:(BOOL)keyFrame
         formatIsAvcc:(BOOL)avcc {
    if (!_open || !_sender || payload.length == 0) return;

    dispatch_async(_sendQueue, ^{
        NDIlib_video_frame_v2_t v;
        memset(&v, 0, sizeof(v));
        v.xres = width;
        v.yres = height;
        v.frame_rate_N = 60000;
        v.frame_rate_D = 1001; // перезапишется из настроек (значение по умолчанию)
        v.frame_format_type = NDIlib_frame_format_type_progressive;
        v.p_data = (uint8_t*)payload.bytes;
        v.line_stride_in_bytes = 0; // для H.264 (HX) не используется
        v.fourcc_type = NDIlib_FOURCC_TYPE_H264;
        v.timestamp = timestampUs;
        v.p_metadata = NULL;
        NDIlib_send_video_async_v2(_sender, &v);
    });
}

- (void)sendAudioPCM:(NSData*)pcm
             channels:(int)channels
           sampleRate:(int)sampleRate
           timestampUs:(int64_t)timestampUs {
    if (!_open || !_sender || pcm.length == 0) return;
    int noSamples = (int)(pcm.length / (channels * 2));

    dispatch_async(_sendQueue, ^{
        NDIlib_audio_frame_v3_t a;
        memset(&a, 0, sizeof(a));
        a.sample_rate = sampleRate;
        a.no_channels = channels;
        a.no_samples = noSamples;
        a.p_data = (uint8_t*)pcm.bytes;
        a.channel_stride_in_bytes = noSamples * 2;
        a.timestamp = timestampUs;
        a.p_metadata = NULL;
        NDIlib_send_audio_async(_sender, &a);
    });
}

- (NSString*)pollTally {
    if (!_open || !_tallyRecv) return nil;

    NDIlib_video_frame_v2_t video;
    NDIlib_audio_frame_v2_t audio;
    NDIlib_metadata_frame_t meta;
    memset(&video, 0, sizeof(video));
    memset(&audio, 0, sizeof(audio));
    memset(&meta, 0, sizeof(meta));

    switch (NDIlib_recv_capture_v3(_tallyRecv, &video, &audio, &meta, 0)) {
        case NDIlib_frame_type_metadata: {
            NSString *result = nil;
            if (meta.p_data) {
                NSString *json = [NSString stringWithUTF8String:meta.p_data];
                if ([json containsString:@"\"tally.program\":true"] || [json containsString:@"\"tally\" : {\"program\": true}"]) {
                    result = @"program";
                } else if ([json containsString:@"\"tally.preview\":true"] || [json containsString:@"\"tally\" : {\"preview\": true}"]) {
                    result = @"preview";
                }
            }
            NDIlib_recv_free_metadata(_tallyRecv, &meta);
            return result;
        }
        case NDIlib_frame_type_video:
            NDIlib_recv_free_video_v2(_tallyRecv, &video);
            break;
        case NDIlib_frame_type_audio:
            NDIlib_recv_free_audio_v2(_tallyRecv, &audio);
            break;
        default:
            break;
    }
    return nil;
}

@end
