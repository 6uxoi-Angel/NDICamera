#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Тонкая ObjC++ обёртка над NDI SDK (iOS, arm64).
/// Реализация в NDINative.mm — там подключаются заголовки SDK.
@interface NDINative : NSObject

/// Открыть NDI-отправитель.
/// - name: имя источника (видно в OBS)
/// - targetIP: если не nil — ручной IP приёмника (для режима "Ручной IP")
/// - discoveryServer: если не nil — адрес NDI Discovery Server (fallback для mDNS)
/// - localIP: если не nil — локальный IP для выбора сетевого интерфейса
/// Вернёт NO при неудаче; причина — в lastErrorMessage.
- (BOOL)openWithName:(NSString*)name
              targetIP:(nullable NSString*)targetIP
       discoveryServer:(nullable NSString*)discoveryServer
               localIP:(nullable NSString*)localIP;

/// Текст последней ошибки (после openWithName..., если вернулся NO).
@property (nonatomic, readonly, copy) NSString *lastErrorMessage;

- (void)close;
- (BOOL)isOpen;

/// Отправить закодированный кадр H.264 (payload = SPS/PPS + данные кадра в формате avcc/annexB).
/// timestampUs — в 100 нс единицах (как требует NDI).
- (void)sendVideoH264:(NSData*)payload
                 width:(int)width
                height:(int)height
         timestampUs:(int64_t)timestampUs
              keyFrame:(BOOL)keyFrame
         formatIsAvcc:(BOOL)avcc;

/// Отправить PCM Int16 (interleaved). Массив — 1 кадр аудио.
- (void)sendAudioPCM:(NSData*)pcm
             channels:(int)channels
           sampleRate:(int)sampleRate
           timestampUs:(int64_t)timestampUs;

/// Опросить tally-метаданные (program/preview) из обратного канала.
/// Возвращает nil или @"program"/@"preview".
- (nullable NSString*)pollTally;

@end

NS_ASSUME_NONNULL_END
