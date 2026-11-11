#import <Cocoa/Cocoa.h>

typedef BOOL (^AxeToolAuthority)(void);
typedef void (^AxeToolReply)(NSDictionary *result);

/// Writes a numeric knob. Production: AxeNativeBridge (Axe-Edit's own command).
@protocol AxeParameterWriter <NSObject>
- (NSDictionary *)parameterForAccessibilityNode:(id)node failure:(NSString **)failure;
- (BOOL)setDisplayValue:(double)value forAccessibilityNode:(id)node failure:(NSString **)failure;
@optional
/// Whether this writer supports the native bypass action for the current build.
- (BOOL)nativeBypassAvailable;
/// Set the selected effect's bypass through the editor's native toggle action.
- (BOOL)setBypassed:(BOOL)bypassed forAccessibilityNode:(id)node failure:(NSString **)failure;
/// Learn memory-layout offsets from the visible controls (no-op once known).
- (void)calibrateWithAccessibilityNodes:(NSArray *)nodes;
@end

@interface AxeEditorTools : NSObject
@property(nonatomic, weak) NSView *editor;
/// Defaults to [AxeNativeBridge shared]; tests substitute a fixture writer.
@property(nonatomic, strong) id<AxeParameterWriter> parameterWriter;
/// Defaults to [AxeAudioClips shared]; tests substitute a temporary library.
@property(nonatomic, strong) id audioClips;
+ (instancetype)shared;
+ (NSArray<NSDictionary *> *)specifications;
+ (NSString *)systemPrompt;
- (NSDictionary *)inspect;
- (NSDictionary *)diagnostics;
- (void)call:(NSString *)name arguments:(NSDictionary *)arguments
   authority:(AxeToolAuthority)authority reply:(AxeToolReply)reply;
@end
