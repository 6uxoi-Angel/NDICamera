#import "NDINative.h"
// ---- NDI SDK (v6) ----
// Заголовки SDK лежат в NDISDK/include (см. README)
#import <Processing.NDI.Lib.h>
#import <Processing.NDI.structs.h>
#import <pthread.h>
#include <atomic>

// Что исправлено по сравнению с прошлой версией (причины SIGSEGV на START):
//
// 1) NDIlib_send_send_video_async_v2 НЕ копирует данные: SDK держит указатель
//    p_data до следующего вызова send (см. Processing.NDI.Send.h). Swift-`Data`
//    жил только внутри dispatch-блока и освобождался (страницы unmap) раньше —
//    рабочий поток NDI читал/писал уже невалидную память → SIGSEGV
//    (в крэш-логе: запись сразу за границей MALLOC_SMALL-региона).
//    Теперь буфер последнего кадра удерживается сильной ссылкой (_heldPayload)
//    ровно столько, сколько требует контракт SDK.
//
// 2) Указатель отправителя читался из потока камеры и мог «пережить»
//    NDIlib_send_destroy() (stop/reconnect) → use-after-free. Теперь ВСЕ
//    обращения к SDK (open/close/send/poll) сериализованы на одной очереди и
//    состояние перепроверяется уже внутри блока.
//
// 3) NDIlib_destroy() при каждой остановке разрушала глобальное состояние SDK
//    (mDNS/worker-потоки). Теперь initialize один раз на процесс, destroy нет.
//
// 4) Кадры отправлялись с timecode=0 (1970 год!) и захардкоженным 60000/1001;
//    timecode и fps теперь передаются корректно (A/V-синхронизация в OBS).

@implementation NDINative {
    // Доступ к полям ниже — ТОЛЬКО на _sendQueue (кроме atomic-счётчиков)
    NDIlib_send_instance_t _sender;
    NDIlib_recv_instance_t _tallyRecv;
    BOOL _open;
    dispatch_queue_t _sendQueue;
    NSString *_sourceName;
    NSString *_lastErrorMessage;
    NSData *_heldPayload;       // буфер последнего async-кадра (контракт SDK)
    int _fpsN;
    int _fpsD;
    std::atomic<long long> _videoSent;
    std::atomic<long long> _droppedVideo;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _sendQueue = dispatch_queue_create("ndi.native.send", DISPATCH_QUEUE_SERIAL);
        _open = NO;
        _sender = NULL;
        _tallyRecv = NULL;
        _lastErrorMessage = @"";
        _fpsN = 30000;
        _fpsD = 1000;
        _videoSent.store(0);
        _droppedVideo.store(0);
    }
    return self;
}

// Инициализация SDK — ровно один раз за процесс.
// NDIlib_destroy() из close() УБРАНА: глобальный teardown между
// stop/start гоняет потоки discovery и роняет процесс.
static dispatch_once_t gNDIOnce;
static BOOL gNDIInitOK = NO;

+ (BOOL)ensureSDKInitialized {
    dispatch_once(&gNDIOnce, ^{
        gNDIInitOK = NDIlib_initialize();
    });
    return gNDIInitOK;
}

- (NSString*)lastErrorMessage {
    __block NSString *msg;
    dispatch_sync(_sendQueue, ^{ msg = self->_lastErrorMessage; });
    return msg;
}

- (BOOL)openWithName:(NSString*)name
            targetIP:(NSString*)targetIP
     discoveryServer:(NSString*)discoveryServer
             localIP:(NSString*)localIP
                fpsN:(int)fpsN
                fpsD:(int)fpsD {
    __block BOOL result = NO;
    dispatch_barrier_sync(_sendQueue, ^{
        if (self->_open) { result = YES; return; }
        if (![NDINative ensureSDKInitialized]) {
            self->_lastErrorMessage = @"NDIlib_initialize() вернул false (лицензия/архитектура)";
            result = NO; return;
        }
        NSString *effectiveName = name;
        if (!effectiveName.length) effectiveName = @"iPhoneCamera";
        self->_sourceName = [effectiveName copy];
        self->_fpsN = fpsN > 0 ? fpsN : 30000;
        self->_fpsD = fpsD > 0 ? fpsD : 1000;
        NDIlib_send_create_t create;
        memset(&create, 0, sizeof(create));
        create.p_ndi_name = [effectiveName UTF8String];
        create.p_groups = NULL;
        create.clock_video = true;
        create.clock_audio = true;
        self->_sender = NDIlib_send_create(&create);
        if (!self->_sender) {
            self->_lastErrorMessage = @"NDIlib_send_create() не удался";
            result = NO; return;
        }
        // Обратный канал для tally: подписываемся на СОБСТВЕННОЕ имя источника
        // и берём только метаданные (DistroAV/OBS шлёт tally XML-кадром).
        // Раньше source_to_connect_to был пустым — подписки не было вовсе.
        NDIlib_recv_create_v3_t rc;
        memset(&rc, 0, sizeof(rc));
        NDIlib_source_t src;
        memset(&src, 0, sizeof(src));
        src.p_ndi_name = [effectiveName UTF8String];
        src.p_url_address = NULL;   // SDK сам найдёт источник по discovery
        rc.source_to_connect_to = src;
        rc.color_format = NDIlib_recv_color_format_BGRX_BGRA;
        rc.bandwidth = NDIlib_recv_bandwidth_metadata_only;
        rc.allow_video_fields = false;
        rc.p_ndi_recv_name = [effectiveName UTF8String];
        self->_tallyRecv = NDIlib_recv_create_v3(&rc);   // NULL не фатален
        self->_lastErrorMessage = @"";
        self->_open = YES;
        result = YES;
    });
    return result;
}

- (void)close {
    dispatch_barrier_sync(_sendQueue, ^{
        if (self->_tallyRecv) { NDIlib_recv_destroy(self->_tallyRecv); self->_tallyRecv = NULL; }
        if (self->_sender) {
            NDIlib_send_destroy(self->_sender);
            self->_sender = NULL;
        }
        self->_heldPayload = nil;   // буфер больше не нужен SDK
        self->_open = NO;
    });
}

- (BOOL)isOpen {
    __block BOOL v;
    dispatch_sync(_sendQueue, ^{ v = self->_open && self->_sender != NULL; });
    return v;
}

- (void)sendVideoNV12:(NSData*)payload
                width:(int)width
               height:(int)height
           timecodeUs:(int64_t)timecodeUs {
    const NSUInteger need = (NSUInteger)width * (NSUInteger)height * 3 / 2;
    if (width <= 0 || height <= 0 || (width & 1) || (height & 1) || payload.length < need) {
        _droppedVideo.fetch_add(1);
        return;
    }
    NSData *strongPayload = payload;   // блок владеет буфером до исполнения
    dispatch_barrier_async(_sendQueue, ^{
        // Перепроверка состояния НА ОЧЕРЕДИ: close() может уже отработать —
        // тогда _open==NO и отправлять некуда (раньше здесь был UAF).
        if (!self->_open || !self->_sender) return;
        NDIlib_video_frame_v2_t v;
        memset(&v, 0, sizeof(v));
        v.xres = width;
        v.yres = height;
        v.frame_rate_N = self->_fpsN;
        v.frame_rate_D = self->_fpsD;
        v.FourCC = NDIlib_FourCC_video_type_NV12;
        v.picture_aspect_ratio = (float)width / (float)height;
        v.frame_format_type = NDIlib_frame_format_type_progressive;
        v.timecode = timecodeUs;               // 100 нс от unix-эпохи (НЕ timestamp!)
        v.p_data = (uint8_t*)strongPayload.bytes;
        v.line_stride_in_bytes = width;        // NV12 плотно: строка Y = width байт
        v.p_metadata = NULL;
        // Контракт async-send: буфер должен жить до СЛЕДУЮЩЕГО вызова/destroy.
        // Держим его в _heldPayload — OS не сможет освободить память.
        self->_heldPayload = strongPayload;
        NDIlib_send_send_video_async_v2(self->_sender, &v);
        self->_videoSent.fetch_add(1);
    });
}

- (void)sendAudioFLTP:(NSData*)fltp
             channels:(int)channels
           sampleRate:(int)sampleRate
           timecodeUs:(int64_t)timecodeUs {
    if (channels <= 0 || sampleRate <= 0 || fltp.length == 0) return;
    if (fltp.length % ((NSUInteger)channels * 4) != 0) return;
    const int noSamples = (int)(fltp.length / ((NSUInteger)channels * 4)); // float32 планар
    NSData *strongAudio = fltp;
    dispatch_barrier_async(_sendQueue, ^{
        if (!self->_open || !self->_sender) return;
        NDIlib_audio_frame_v3_t a;
        memset(&a, 0, sizeof(a));
        a.sample_rate = sampleRate;
        a.no_channels = channels;
        a.no_samples = noSamples;
        a.timecode = timecodeUs;
        a.FourCC = NDIlib_FourCC_audio_type_FLTP;
        a.p_data = (uint8_t*)strongAudio.bytes;
        a.channel_stride_in_bytes = noSamples * 4;
        a.p_metadata = NULL;
        NDIlib_send_send_audio_v3(self->_sender, &a);   // синхронная: копирует сразу
    });
}

- (void)pollTallyWithCompletion:(void (^)(NSString * _Nullable))completion {
    if (!completion) return;
    dispatch_barrier_async(_sendQueue, ^{
        NSString *result = nil;
        if (self->_open && self->_tallyRecv) {
            NDIlib_video_frame_v2_t video;
            NDIlib_audio_frame_v3_t audio;
            NDIlib_metadata_frame_t meta;
            memset(&video, 0, sizeof(video));
            memset(&audio, 0, sizeof(audio));
            memset(&meta, 0, sizeof(meta));
            switch (NDIlib_recv_capture_v3(self->_tallyRecv, &video, &audio, &meta, 0)) {
                case NDIlib_frame_type_metadata: {
                    if (meta.p_data) {
                        NSString *xml = [NSString stringWithUTF8String:meta.p_data] ?: @"";
                        // Стандартный NDI tally: <Tally><program>1</program><preview>0</preview></Tally>
                        // (DistroAV/OBS шлёт именно так). Плюс запасной вариант — JSON.
                        BOOL program = [xml containsString:@"<program>1"]
                                    || [xml containsString:@"\"program\":true"]
                                    || [xml containsString:@"\"program\": true"];
                        BOOL preview = [xml containsString:@"<preview>1"]
                                    || [xml containsString:@"\"preview\":true"]
                                    || [xml containsString:@"\"preview\": true"];
                        if (program) result = @"program";
                        else if (preview) result = @"preview";
                    }
                    NDIlib_recv_free_metadata(self->_tallyRecv, &meta);
                    break;
                }
                case NDIlib_frame_type_video:
                    NDIlib_recv_free_video_v2(self->_tallyRecv, &video);
                    break;
                case NDIlib_frame_type_audio:
                    NDIlib_recv_free_audio_v3(self->_tallyRecv, &audio);
                    break;
                default:
                    break;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
    });
}

/// Счётчики для диагностики (вызывается редко, вне горячего пути)
- (NSDictionary*)stats {
    __block NSDictionary *out;
    dispatch_sync(_sendQueue, ^{
        out = @{@"sent": @(self->_videoSent.load()),
                @"dropped": @(self->_droppedVideo.load()),
                @"open": @(self->_open)};
    });
    return out;
}

@end
