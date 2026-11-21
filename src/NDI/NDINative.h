#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Тонкая ObjC++ обёртка над NDI SDK (iOS, arm64).
/// Реализация в NDINative.mm — там подключаются заголовки SDK.
///
/// Потокобезопасность: ВСЕ обращения к SDK идут через одну сериальную очередь;
/// открытием/закрытием/отправкой нельзя «переехать» друг друга. Это чинит
/// SIGSEGV на кнопке START (SDK читал уже освобождённые Swift-буферы кадров
/// и уничтоженный инстанс отправителя).
@interface NDINative : NSObject

/// Открыть NDI-отправитель.
/// - name: имя источника (видно в OBS)
/// - targetIP: если не nil — ручной IP приёмника (для режима "Ручной IP")
/// - discoveryServer: если не nil — адрес NDI Discovery Server (fallback для mDNS)
/// - localIP: если не nil — локальный IP для выбора сетевого интерфейса
/// - fpsN/fpsD: числитель/знаменатель кадровой частоты (30 → 30000/1000)
/// Вернёт NO при неудаче; причина — в lastErrorMessage.
- (BOOL)openWithName:(NSString*)name
            targetIP:(nullable NSString*)targetIP
     discoveryServer:(nullable NSString*)discoveryServer
             localIP:(nullable NSString*)localIP
                fpsN:(int)fpsN
                fpsD:(int)fpsD;

/// Текст последней ошибки (после openWithName..., если вернулся NO).
@property (nonatomic, readonly, copy) NSString *lastErrorMessage;

- (void)close;
- (BOOL)isOpen;

/// Отправить кадр NV12 (Y-плоскость + CbCr-плоскость, плотно упакованные:
/// строка = width байт, Chroma начинается со смещения width*height).
/// timecodeUs — в 100 нс интервалах от unix-эпохи (как требует NDI).
- (void)sendVideoNV12:(NSData*)payload
                width:(int)width
               height:(int)height
           timecodeUs:(int64_t)timecodeUs;

/// Отправить аудио float32 планарное (FLTP): канал 0 целиком, затем канал 1...
- (void)sendAudioFLTP:(NSData*)fltp
             channels:(int)channels
           sampleRate:(int)sampleRate
           timecodeUs:(int64_t)timecodeUs;

/// Опросить tally-метаданные (program/preview) из обратного канала.
/// Выполняется на внутренней очереди SDK; результат — в main-потоке.
- (void)pollTallyWithCompletion:(void (^)(NSString * _Nullable result))completion
        NS_SWIFT_NAME(pollTally(completion:));

@end

NS_ASSUME_NONNULL_END
