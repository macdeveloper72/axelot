// Read the owned copy's Axe-Edit accessibility tree; write parameters only
// through Axe-Edit's own Undo-aware command path (NativeBridge). Axe-Edit owns
// the MIDI transport; no SysEx, mouse or keyboard synthesis is used.
#import "EditorTools.h"
#import "NativeBridge.h"
#import "AudioClips.h"
#import "AudioTools.h"
#import <objc/message.h>
#include <cmath>

static id attr(id node, NSString *name) {
    NSDictionary *selectors = @{@"role":@"accessibilityRole",@"label":@"accessibilityLabel",
        @"value":@"accessibilityValue",@"children":@"accessibilityChildren",@"min":@"accessibilityMinValue",
        @"max":@"accessibilityMaxValue",@"enabled":@"isAccessibilityEnabled",@"title":@"accessibilityTitle",@"focus":@"accessibilityFocusedUIElement",@"window":@"accessibilityWindow"};
    SEL selector = NSSelectorFromString(selectors[name]);
    @try {
        if (![node respondsToSelector:selector]) return nil;
        if ([name isEqual:@"enabled"]) return @(((BOOL (*)(id, SEL))objc_msgSend)(node, selector));
        return ((id (*)(id, SEL))objc_msgSend)(node, selector);
    } @catch (NSException *exception) { return nil; }
}
static NSString *labelOf(id node) {
    for(NSString *key in @[@"label",@"title"]) {id value=attr(node,key);if([value isKindOfClass:NSString.class] && [value length])return value;}
    return @"";
}
static NSNumber *numberOf(id value) {
    if([value isKindOfClass:NSNumber.class])return value;
    if(![value isKindOfClass:NSString.class])return nil;
    NSScanner *scanner=[NSScanner scannerWithString:value];double number=0;
    return [scanner scanDouble:&number] && scanner.atEnd && std::isfinite(number) ? @(number) : nil;
}
static NSNumber *boolOf(id value) {
    if([value isKindOfClass:NSNumber.class])return @([value boolValue]);
    if([value isKindOfClass:NSString.class]) {NSString *s=[value lowercaseString];if([@[@"on",@"true",@"1"] containsObject:s])return @YES;if([@[@"off",@"false",@"0"] containsObject:s])return @NO;}
    return nil;
}
static NSArray *nodesOf(id root) {
    if (!root) return @[];
    NSMutableArray *out = [NSMutableArray array], *queue = [NSMutableArray arrayWithObject:root];
    NSHashTable *seen = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    for (NSUInteger i=0; i<queue.count && out.count<4096; ++i) {
        id node=queue[i]; if ([seen containsObject:node]) continue;
        [seen addObject:node]; [out addObject:node];
        id children=attr(node,@"children");
        if ([children isKindOfClass:NSArray.class] && queue.count+[children count]<8192) [queue addObjectsFromArray:children];
    }
    return out;
}
static BOOL allowed(id node, SEL action) {
    if(![node respondsToSelector:action] || [attr(node,@"enabled") isEqual:@NO])return NO;
    SEL query=@selector(isAccessibilitySelectorAllowed:);
    @try {return ![node respondsToSelector:query] || ((BOOL (*)(id,SEL,SEL))objc_msgSend)(node,query,action);}
    @catch(NSException *exception) {return NO;}
}
static BOOL press(id node) {
    SEL selector=@selector(accessibilityPerformPress);
    @try { return allowed(node,selector) && ((BOOL (*)(id,SEL))objc_msgSend)(node,selector); }
    @catch (NSException *exception) { return NO; }
}
static BOOL setValue(id node,id value) {
    SEL selector=@selector(setAccessibilityValue:);
    @try {
        if (!allowed(node,selector)) return NO;
        // JUCE's native setter takes NSString and calls setValueAsString.
        // Passing NSNumber directly is an ABI-compatible but invalid object.
        NSString *text=[value isKindOfClass:NSString.class] ? value : ([value isKindOfClass:NSNumber.class] ? [value stringValue] : nil);
        if(!text)return NO;
        ((void (*)(id,SEL,id))objc_msgSend)(node,selector,text); return YES;
    } @catch (NSException *exception) { return NO; }
}
// Axe-Edit's custom knobs expose a read-only editable Label rather than a
// slider value interface. Its press action opens JUCE's real TextEditor.
static NSString *textOf(id node) {
    id value=attr(node,@"value");return [value isKindOfClass:NSString.class] ? value : labelOf(node);
}
static id numericLabel(id slider) {
    for(id child in nodesOf(slider)) if(child!=slider && [attr(child,@"role") isEqual:NSAccessibilityTextAreaRole])return child;
    return nil;
}
static NSNumber *displayNumber(id node) {
    NSNumber *value=numberOf(attr(node,@"value"));if(value)return value;
    NSString *text=textOf(numericLabel(node) ?: node);
    NSScanner *scanner=[NSScanner scannerWithString:text];double number=0;
    if(![scanner scanDouble:&number] || !std::isfinite(number))return nil;
    // A numeric display may include units (dB, Hz, %, ms); never parse a
    // parameter title or enum as a numeric value.
    NSString *suffix=[[text substringFromIndex:scanner.scanLocation] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSCharacterSet *units=[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ%°/ "];
    return [suffix rangeOfCharacterFromSet:units.invertedSet].location==NSNotFound ? @(number) : nil;
}
// Text fields (scene name) are edited only through an accessibility value
// setter the control itself exposes; otherwise the edit is refused.
static BOOL editText(id node,NSString *text,NSString **failure) {
    if(allowed(node,@selector(setAccessibilityValue:)))return setValue(node,text);
    if(failure)*failure=@"This control exposes no native value setter; not edited";
    return NO;
}
// Half a unit of the precision the editor displays (e.g. "2.51" -> 0.005).
static double displayTolerance(NSString *label) {
    NSString *text=[[label componentsSeparatedByString:@","] firstObject];
    NSRange colon=[text rangeOfString:@":"]; if(colon.location!=NSNotFound) text=[text substringFromIndex:colon.location+1];
    NSRange dot=[text rangeOfString:@"."]; NSUInteger digits=0;
    if(dot.location!=NSNotFound) for(NSUInteger i=dot.location+1;i<text.length && [NSCharacterSet.decimalDigitCharacterSet characterIsMember:[text characterAtIndex:i]];++i) ++digits;
    return 0.5*std::pow(10.0,-(double)digits)+1e-9;
}
// Axe-Fx III effect types and their firmware instance IDs (first ID, 4 instances),
// matching the bridge's kInstanceTypes table. Lets the agent insert blocks by name.
static NSArray<NSDictionary *> *effectTypes(void) {
    static NSArray *types; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *rows=@[@[@"Compressor",@46],@[@"Graphic EQ",@50],@[@"Parametric EQ",@54],@[@"Amp",@58],@[@"Cab",@62],@[@"Reverb",@66],
            @[@"Delay",@70],@[@"Multitap Delay",@74],@[@"Chorus",@78],@[@"Flanger",@82],@[@"Rotary",@86],@[@"Phaser",@90],@[@"Wah",@94],
            @[@"Formant",@98],@[@"Volume/Pan",@102],@[@"Tremolo/Panner",@106],@[@"Pitch",@110],@[@"Filter",@114],@[@"Drive",@118],
            @[@"Enhancer",@122],@[@"Mixer",@126],@[@"Synth",@130],@[@"Vocoder",@134],@[@"Megatap Delay",@138],@[@"Crossover",@142],
            @[@"Gate/Expander",@146],@[@"Ring Modulator",@150],@[@"Multiband Compressor",@154],@[@"Ten-Tap Delay",@158],
            @[@"Resonator",@162],@[@"Looper",@166],@[@"Tone Match",@170],@[@"Plex Delay",@178],@[@"IR Player",@195]];
        NSMutableArray *out=[NSMutableArray array];
        // Input 1-4 and Output 1-4 are single-instance blocks (Fractal 3rd-party IDs);
        // their mapping is not yet confirmed on a live preset, so flag it.
        [out addObject:@{@"type":@"Input",@"instances":@[@37,@38,@39,@40],@"verified":@NO}];
        [out addObject:@{@"type":@"Output",@"instances":@[@42,@43,@44,@45],@"verified":@NO}];
        for(NSArray *r in rows){NSInteger f=[r[1] integerValue];[out addObject:@{@"type":r[0],@"instances":@[@(f),@(f+1),@(f+2),@(f+3)],@"verified":@YES}];}
        types=out;
    });
    return types;
}
static NSArray *effectTypeNames(void) { NSMutableArray *n=[NSMutableArray array];for(NSDictionary *t in effectTypes())[n addObject:t[@"type"]];return n; }
static NSDictionary *errorResult(NSString *message) { return @{@"ok":@NO,@"error":message}; }
static NSString *parameterName(NSString *label) {
    return [[label componentsSeparatedByString:@":"] firstObject];
}

@interface AxeEditorTools ()
@property(nonatomic, strong) NSMutableDictionary<NSString *,NSDictionary *> *completed;
@property(nonatomic) BOOL executing;
@end

@implementation AxeEditorTools
+ (instancetype)shared {
    static AxeEditorTools *tools; static dispatch_once_t once;
    dispatch_once(&once, ^{ tools=[AxeEditorTools new]; tools.completed=[NSMutableDictionary dictionary]; });
    return tools;
}
+ (NSArray *)specifications {
    NSDictionary *string=@{@"type":@"string"}, *number=@{@"type":@"number"};
    NSDictionary *context=@{@"type":@"string",@"description":@"Exact context token from the latest axefx_inspect result; refresh after each selection or edit."};
    NSDictionary *key=@{@"type":@"string",@"minLength":@1,@"maxLength":@128,@"description":@"Unique operation ID. Retry the same operation with the same key; never replay an uncertain mutation with a new key."};
    NSMutableArray *specs=[NSMutableArray array];
    void (^add)(NSString*,NSString*,NSDictionary*,NSArray*)=^(NSString *name,NSString *description,NSDictionary *properties,NSArray *required) {
        [specs addObject:@{@"name":name,@"description":description,@"inputSchema":@{@"type":@"object",@"properties":properties,@"required":required,@"additionalProperties":@NO}}];
    };
    add(@"axefx_inspect",@"Read the actual connected Axe-Edit UI: current Axe-Fx preset, eight scenes, grid blocks, selected block/channel, parameter values and observed ranges. Never invent missing values.",@{},@[]);
    NSDictionary *base=@{@"expected_context":context,@"operation_id":key};
    NSMutableDictionary *(^props)(NSDictionary*)=^NSMutableDictionary*(NSDictionary *extra) { NSMutableDictionary *p=[base mutableCopy];[p addEntriesFromDictionary:extra];return p; };
    add(@"axefx_select_block",@"Select a grid cell, including an Empty cell before insertion. Supply all three required arguments: block = exact label from axefx_inspect.blocks, expected_context = latest inspection's context_token, operation_id = unique ID for this selection (preserve on retries). Returns the selected block's actual parameters; does not insert or remove blocks.",props(@{@"block":string}),@[@"block",@"expected_context",@"operation_id"]);
    add(@"axefx_add_block",@"Insert an effect block into the selected empty grid cell. First select an exact empty cell with axefx_select_block, inspect again, then pass effect_type (a name from axefx_inspect.effect_catalog, e.g. Drive, Amp, Cab, Delay, Reverb); the lowest free instance is used. Alternatively pass effect_id = one of that type's available_instances. Does not connect cables or select effect models; connect afterwards with axefx_connect_blocks. Requires capabilities.block_insertion.",props(@{@"effect_type":@{@"type":@"string",@"enum":effectTypeNames()},@"effect_id":@{@"type":@"integer",@"minimum":@1,@"maximum":@65535}}),@[@"expected_context",@"operation_id"]);
    add(@"axefx_remove_block",@"Remove the selected occupied grid cell through the native Delete Block command. Requires capabilities.block_deletion. Inspect and select exactly one cell first; deletion can remove its cables. Never stores the preset.",props(@{}),@[@"expected_context",@"operation_id"]);
    NSDictionary *endpoints=@{@"source":@{@"type":@"string",@"description":@"Exact occupied grid block label from the latest inspection."},@"destination":@{@"type":@"string",@"description":@"Exact occupied grid block label in the immediately following column. Use shunts for gaps."}};
    add(@"axefx_connect_blocks",@"Connect two occupied cells in adjacent columns, left to right, using Axe-Edit's native cable command. Exact inspected source/destination labels required. Preserves other cables; does not insert shunts. Repeated connection is a verified no-op.",props(endpoints),@[@"source",@"destination",@"expected_context",@"operation_id"]);
    add(@"axefx_disconnect_blocks",@"Remove only the cable between two occupied cells in adjacent columns. Exact inspected source/destination labels required. Preserves all other cables. Already absent is a verified no-op.",props(endpoints),@[@"source",@"destination",@"expected_context",@"operation_id"]);
    add(@"axefx_set_parameter",@"Change one numeric knob of the selected effect through Axe-Edit's own Undo-aware parameter command (the same path as typing a value into the knob). Requires the exact current value as expected_value and a value within the inspected minimum..maximum. Only parameters inspected as writable=true can be set; not_writable_reason explains the rest. Returns editor readback; the user can undo with Cmd-Z; hardware persistence is not claimed.",props(@{@"parameter":string,@"value":number,@"expected_value":number}),@[@"parameter",@"value",@"expected_value",@"expected_context",@"operation_id"]);
    add(@"axefx_set_bypass",@"Set the selected effect's bypass state in the current scene through the native toggle (verified Axe-Edit 1.15.03 only). Inspect capabilities.effect_bypass first. Success requires both button and grid readback.",props(@{@"bypassed":@{@"type":@"boolean"}}),@[@"bypassed",@"expected_context",@"operation_id"]);
    add(@"axefx_select_channel",@"Choose an existing channel A-D for the selected effect in the current scene. Other scenes/channels are not rewritten.",props(@{@"channel":@{@"type":@"string",@"enum":@[@"A",@"B",@"C",@"D"]}}),@[@"channel",@"expected_context",@"operation_id"]);
    add(@"axefx_select_scene",@"Select one of the Axe-Fx's eight existing scene slots (1-8). Build a scene by selecting it, setting block bypass/channels/parameters, and naming it. There are no extra scene slots.",props(@{@"scene":@{@"type":@"integer",@"minimum":@1,@"maximum":@8}}),@[@"scene",@"expected_context",@"operation_id"]);
    add(@"axefx_name_scene",@"Rename the current scene using Axe-Edit's editable scene-name control; changes the edit buffer, never stores the preset.",props(@{@"name":@{@"type":@"string",@"minLength":@1,@"maxLength":@32}}),@[@"name",@"expected_context",@"operation_id"]);
    [specs addObjectsFromArray:[AxeAudioTools specifications]];
    return specs;
}
+ (NSString *)systemPrompt {
    return @"You are an active guitar-tone assistant for the user's Axe-Fx III, embedded in its real Axe-Edit editor. Help create useful guitar tones and scenes from musical descriptions, playing feedback, reference rigs and recordings when supported. Use the provided axefx_* tools to inspect and edit the actual connected Axe-Fx through Axe-Edit. The user's tone-making request authorizes reasonable current-edit-buffer changes; do not merely give manual knob instructions when a supported tool can perform the requested edit. Start with axefx_inspect, select the intended block, and use observed parameter names, values, channels, bypass state and known effect identities. Respect each parameter's inspected minimum/maximum and only set parameters marked writable=true; never invent ranges. Each edit is a normal Axe-Edit edit the user can undo with Cmd-Z. Parameter changes affect the block channel and may also affect other scenes using that same channel; explain this when building scene-specific tones. Work in small musical steps and ask the user to play and report what they hear.\n\nTools: axefx_inspect reads current preset/scenes/effects/selected parameters and context. axefx_select_block selects an existing grid block. axefx_set_parameter changes a writable numeric knob using its expected prior value. axefx_set_bypass and axefx_select_channel configure a block for the current scene. axefx_select_scene selects one of the eight fixed slots; use it with bypass/channel/parameter edits and axefx_name_scene to build scenes. axefx_add_block and axefx_remove_block edit the selected grid cell when inspection reports their capabilities. Select an empty cell before insertion and inspect after selection; insert by effect_type using names from inspect.effect_catalog (never guess IDs). To build a chain: inspect -> select empty cell -> inspect -> axefx_add_block(effect_type) -> inspect -> axefx_connect_blocks from the left neighbour to the new block and from the new block to the right neighbour. axefx_connect_blocks and axefx_disconnect_blocks edit one cable between occupied cells in adjacent columns when capabilities.routing_edits is true. Inspect cables after every edit; insert shunts separately to bridge gaps. Effect model changes are not exposed yet; do not claim to perform them or guess UI coordinates.\n\nBuilding a tone from scratch: 1) Inspect and plan one block per column on one row, left to right, e.g. Input -> (Compressor/Drive/Wah optional) -> Amp -> Cab -> (Chorus/Phaser optional) -> Delay -> Reverb -> Output; tell the user the plan in one line. Reuse blocks already present (especially Input 1/Output 1, usually in the first and last columns) instead of inserting duplicates. 2) For each missing block: axefx_select_block on the empty cell -> axefx_inspect -> axefx_add_block(effect_type) -> axefx_inspect. 3) Connect every adjacent pair with axefx_connect_blocks, then inspect and report the final chain from the cables. 4) If any write returns sent_readback_unverified, follow its next_step: inspect; if the block/cable is present continue, never resend the same operation_id; retry with a new operation_id only if it is clearly absent and nothing else changed. Do not abandon the build after one unverified result. 5) Voice the tone: select each block, read its parameters and set only writable ones within their ranges. Typical starting points: Amp gain about 3-5 (clean/crunch) or 6-8 (lead), bass/mid/treble near 5, master moderate; Drive in front of the amp for push; Delay mix about 20-30 % and Reverb mix about 15-25 %. Amp/cab model selection is unavailable, so ask the user to pick models in Axe-Edit and say which style suits the request. 6) Use scenes for variants (clean/rhythm/lead) via bypass and channel per scene, then name them. 7) Ask the user to play and report, adjust in small steps, and never save the preset.\n\nEvery selection or mutation needs the latest expected_context; refresh inspection after each edit. Use a unique operation_id per intended mutation and preserve it on retries. Never retry an uncertain write as a new operation. A disconnected device, stale context, unsupported value, pending operation, or Stop must halt edits. Report tool failures and partial results honestly. Readback verification_scope=axe_edit_ui confirms only the editor's value, not an independent hardware getter or persistence. Never claim to have heard audio: you only receive numeric measurements from the audio tools. Preset Save/Store, raw MIDI, firmware, global settings, shell, filesystem, web, connectors and delegated agents are unavailable. Never instruct a workaround to bypass these limits. Do not save a preset automatically. Keep explanations musical, concise, and specific to the user's guitar-tone goal.\n\nTone matching from audio: the user keeps local clips in the panel's Audio section, marked reference (the tone to match, ideally isolated guitar) or current (a recording of their Axe-Fx tone). axefx_audio_list shows them, axefx_audio_analyze measures one, and axefx_audio_compare reports how the current tone differs from the reference. Workflow: 1) axefx_audio_list; if a reference or current clip is missing, ask the user to import or record one. 2) axefx_inspect the relevant blocks (amp, cab, drive, EQ, delay, reverb). 3) axefx_audio_compare. 4) Explain the biggest differences musically and PROPOSE a short list of concrete changes, each with block, parameter, current -> proposed value and the reason (e.g. high rolloff lower than reference -> raise Cab High Cut); only writable parameters within their inspected ranges, at most about 3-5 changes per round. 5) Do not apply anything until the user explicitly agrees; then apply exactly the approved changes with axefx_set_parameter. 6) Ask the user to play the same part the same way, record a new current take, and compare again, reporting whether the spectral distance shrank. Measurements are proxies that depend on playing and recording; say so when the evidence is weak (mixed sources, different parts, short clips).";
}
- (NSArray *)nodes { return nodesOf(self.editor); }
- (id<AxeParameterWriter>)writer { return self.parameterWriter ?: [AxeNativeBridge shared]; }
- (NSDictionary *)diagnostics {
    NSMutableArray *tree=[NSMutableArray array];
    for(id node in [self nodes]) {
        NSMutableDictionary *row=[@{@"class":NSStringFromClass([node class]),@"label":labelOf(node),@"settable":@(allowed(node,@selector(setAccessibilityValue:))),@"pressable":@(allowed(node,@selector(accessibilityPerformPress)))} mutableCopy];
        for(NSString *key in @[@"role",@"value",@"min",@"max",@"enabled"]) {id value=attr(node,key);if([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class])row[key]=value;}
        [tree addObject:row];
    }
    return @{@"inspection":[self inspect],@"tree":tree};
}
- (id)find:(NSString *)role label:(NSString *)label nodes:(NSArray *)nodes {
    for(id node in nodes) if ((!role || [attr(node,@"role") isEqual:role]) &&
        ([labelOf(node) isEqual:label] || [labelOf(node) hasPrefix:[label stringByAppendingString:@":"]])) return node;
    return nil;
}
- (NSDictionary *)inspect {
    NSArray *nodes=[self nodes];
    if([self.writer respondsToSelector:@selector(calibrateWithAccessibilityNodes:)]) [self.writer calibrateWithAccessibilityNodes:nodes];
    BOOL connected=NO;
    NSMutableArray *grid=[NSMutableArray array];
    NSMutableArray *blocks=[NSMutableArray array], *parameters=[NSMutableArray array], *scenes=[NSMutableArray array];
    NSMutableDictionary *context=[NSMutableDictionary dictionary];
    for(id node in nodes) {
        NSString *label=labelOf(node), *role=attr(node,@"role"); id value=attr(node,@"value");
        if ([label isEqual:@"Connected!"] || [value isEqual:@"Connected!"]) connected=YES;
        for(NSString *field in @[@"Preset Number",@"Preset Name",@"Scene Number",@"Scene Name"])
            if ([label isEqual:field] || [label hasPrefix:[field stringByAppendingString:@":"]])
                {
                NSString *text=[value isKindOfClass:NSString.class] ? value : label;
                NSString *prefix=[field stringByAppendingString:@":"];
                context[field]=[text hasPrefix:prefix] ? [[text substringFromIndex:prefix.length] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] : text;
            }
        if ([label hasPrefix:@"Grid row "]) {
            [grid addObject:label];
            BOOL selected=[boolOf(value) boolValue];
            NSMutableDictionary *cell=[@{@"block":label,@"selected":@(selected)} mutableCopy];
            if([self.writer respondsToSelector:@selector(effectIDForGridNode:)]) {NSNumber *eid=[self.writer effectIDForGridNode:node];if(eid)cell[@"effect_id"]=eid;}
            [blocks addObject:cell];
            if(selected) {context[@"block"]=label;context[@"block_identity"]=[[label componentsSeparatedByString:@":"] firstObject];}
        }
        if ([label hasPrefix:@"Scene "] && [role isEqual:NSAccessibilityButtonRole] &&
            label.length>6 && [NSCharacterSet.decimalDigitCharacterSet characterIsMember:[label characterAtIndex:6]])
            [scenes addObject:@{@"label":label,@"selected":@([boolOf(value) boolValue])}];
        if([label hasPrefix:@"Channel "] && [boolOf(value) boolValue]) context[@"channel"]=label;
        if([role isEqual:NSAccessibilitySliderRole]) {
            value=displayNumber(node); NSString *why=nil;
            NSDictionary *native=[self.writer parameterForAccessibilityNode:node failure:&why];
            NSMutableDictionary *row=[@{@"parameter":parameterName(label),@"label":label,@"value":value ?: NSNull.null,
                @"writable":@(value && native!=nil)} mutableCopy];
            if(native) {
                row[@"minimum"]=native[@"display_min"];row[@"maximum"]=native[@"display_max"];row[@"step"]=@([native[@"step"] doubleValue]*[native[@"scale"] doubleValue]);
                row[@"effect_id"]=native[@"effect"];row[@"parameter_id"]=native[@"parameter"];
            } else row[@"not_writable_reason"]=why ?: @"Unknown";
            [parameters addObject:row];
        }
        if([label hasPrefix:@"Bypass:"] || [label isEqual:@"Bypass"]) context[@"bypassed"]=boolOf(value) ?: NSNull.null;
    }
    NSArray *routing=nil;NSString *routingFailure=nil;
    if([self.writer respondsToSelector:@selector(routingForGridNode:failure:)])for(id node in nodes)if([labelOf(node) hasPrefix:@"Grid row "]) {routing=[self.writer routingForGridNode:node failure:&routingFailure];break;}
    context[@"routing"]=routing ?: NSNull.null;
    context[@"grid"]=grid;
    NSData *encoded=[NSJSONSerialization dataWithJSONObject:context options:NSJSONWritingSortedKeys error:nil];
    NSString *token=[[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding] ?: @"{}";
    connected=connected && context[@"Preset Number"] && context[@"Scene Number"];
    BOOL bypassAvailable=connected && [self.writer respondsToSelector:@selector(nativeBypassAvailable)] && [self.writer nativeBypassAvailable];
    NSMutableSet *used=[NSMutableSet set];for(NSDictionary *b in blocks)if(b[@"effect_id"])[used addObject:b[@"effect_id"]];
    NSMutableArray *catalog=[NSMutableArray array];
    for(NSDictionary *t in effectTypes()){NSMutableArray *free=[NSMutableArray array];for(NSNumber *i in t[@"instances"])if(![used containsObject:i])[free addObject:i];
        [catalog addObject:@{@"type":t[@"type"],@"instances":t[@"instances"],@"available_instances":free,@"id_mapping_verified":t[@"verified"]}];}
    return @{@"effect_catalog":catalog,@"ok":@YES,@"connected":@(connected),@"context":context,@"context_token":token,
        @"blocks":blocks,@"scenes":scenes,@"parameters":parameters,@"cables":routing ?: NSNull.null,@"routing_unavailable_reason":routingFailure ?: (routing ? @"" : @"Routing readback unavailable"),
        @"verification_scope":@"axe_edit_ui",@"hardware_persistence_verified":@NO,
        @"capabilities":@{@"parameter_edit":@(connected),@"effect_bypass_and_channels":@(bypassAvailable),@"effect_bypass":@(bypassAvailable),@"effect_channels":@(connected),@"scene_configuration":@(connected),
            @"effect_model_selection":@NO,@"block_insertion":@(connected && [self.writer respondsToSelector:@selector(nativeBlockEditingAvailable)] && [self.writer nativeBlockEditingAvailable]),@"block_deletion":@(connected && [self.writer respondsToSelector:@selector(nativeBlockEditingAvailable)] && [self.writer nativeBlockEditingAvailable]),@"routing_edits":@(connected && routing!=nil && [self.writer respondsToSelector:@selector(setCableFromNode:toNode:connected:failure:)]),@"preset_store":@NO}};
}
- (void)call:(NSString *)name arguments:(NSDictionary *)args authority:(AxeToolAuthority)authority reply:(AxeToolReply)reply {
    NSAssert(NSThread.isMainThread,@"Editor access must run on the main thread");
    if(!authority()) { reply(errorResult(@"Turn stopped or authority revoked")); return; }
    NSDictionary *definition=nil;for(NSDictionary *spec in [AxeEditorTools specifications])if([spec[@"name"] isEqual:name])definition=spec;
    if(!definition || ![args isKindOfClass:NSDictionary.class]) {reply(errorResult(@"Unknown tool or invalid arguments"));return;}
    NSDictionary *properties=definition[@"inputSchema"][@"properties"];
    for(NSString *field in args)if(!properties[field]) {reply(errorResult(@"Unexpected tool argument"));return;}
    NSMutableArray *missing=[NSMutableArray array];
    for(NSString *field in definition[@"inputSchema"][@"required"])
        if(!args[field] || args[field]==NSNull.null) [missing addObject:field];
    if(missing.count) {
        reply(@{@"ok":@NO,@"error":[NSString stringWithFormat:@"%@: missing required arguments: %@. No editor action was performed. Supply every required argument from the tool schema.",name,[missing componentsJoinedByString:@", "]],
            @"code":@"missing_required_arguments",@"missing_arguments":missing,@"required_arguments":definition[@"inputSchema"][@"required"],@"action_performed":@NO});
        return;
    }
    if([name isEqual:@"axefx_inspect"]) { reply([self inspect]); return; }
    // Audio tools are read-only analysis of local clips: no editor context needed.
    if([name hasPrefix:@"axefx_audio_"]) { [AxeAudioTools call:name arguments:args clips:self.audioClips ?: [AxeAudioClips shared] reply:reply]; return; }
    if(self.executing) { reply(errorResult(@"Another editor operation is pending; inspect and retry later")); return; }
    NSString *key=args[@"operation_id"];
    if([key isKindOfClass:NSString.class] && self.completed[key]) {
        NSDictionary *prior=self.completed[key];
        if([prior[@"name"] isEqual:name] && [prior[@"arguments"] isEqual:args]) reply(prior[@"result"]);
        else reply(errorResult(@"operation_id was already used for a different operation"));
        return;
    }
    if(self.completed.count>=512) {reply(errorResult(@"Operation ledger is full; restart the app before further writes"));return;}
    NSDictionary *before=[self inspect];
    if(![before[@"connected"] boolValue]) { reply(errorResult(@"Axe-Edit does not report a connected Axe-Fx")); return; }
    if(![args[@"expected_context"] isEqual:before[@"context_token"]]) { reply(errorResult(@"Stale editor context; call axefx_inspect again")); return; }
    if(![key isKindOfClass:NSString.class] || !key.length || key.length>256) { reply(errorResult(@"operation_id is required")); return; }
    NSArray *nodes=[self nodes]; id target=nil; BOOL accepted=NO;
    NSString *verifyKind=nil; id wanted=nil; NSString *failure=nil; NSNumber *restore=nil;
    self.executing=YES;
    if([name isEqual:@"axefx_select_block"]) {
        NSString *block=args[@"block"];
        if([block isKindOfClass:NSString.class] && [block hasPrefix:@"Grid row "]) target=[self find:nil label:block nodes:nodes];
        accepted=press(target);verifyKind=@"selected_block";wanted=block;
    } else if([name isEqual:@"axefx_connect_blocks"] || [name isEqual:@"axefx_disconnect_blocks"]) {
        BOOL connect=[name isEqual:@"axefx_connect_blocks"];
        NSString *source=args[@"source"],*destination=args[@"destination"];
        id from=nil,to=nil;NSUInteger fromCount=0,toCount=0;
        if([source isKindOfClass:NSString.class] && [destination isKindOfClass:NSString.class])for(id node in nodes) {
            NSString *label=labelOf(node);if(![label hasPrefix:@"Grid row "] || [label hasSuffix:@": Empty"])continue;
            if([label isEqual:source]) {from=node;++fromCount;}
            if([label isEqual:destination]) {to=node;++toCount;}
        }
        int sr=-1,sc=-1,dr=-1,dc=-1;
        if(fromCount!=1 || toCount!=1 || sscanf([source UTF8String],"Grid row %d column %d:",&sr,&sc)!=2 || sscanf([destination UTF8String],"Grid row %d column %d:",&dr,&dc)!=2 || sr<0 || sr>5 || dr<0 || dr>5 || sc<0 || sc>12 || dc!=sc+1)failure=@"Choose two exact occupied grid labels in adjacent columns, left to right; insert shunts separately for gaps";
        if(![before[@"capabilities"][@"routing_edits"] boolValue])failure=@"Native cable editing or routing readback is unavailable";
        NSDictionary *edge=@{@"source_row":@(sr),@"source_column":@(sc),@"destination_row":@(dr),@"destination_column":@(dc)};
        NSMutableArray *expected=[before[@"cables"] isKindOfClass:NSArray.class] ? [before[@"cables"] mutableCopy] : [NSMutableArray array];
        BOOL exists=[expected containsObject:edge];
        if(connect && !exists)[expected addObject:edge];if(!connect)[expected removeObject:edge];
        if(!failure)accepted=exists==connect || [self.writer setCableFromNode:from toNode:to connected:connect failure:&failure];
        verifyKind=@"routing";wanted=expected;
    } else if([name isEqual:@"axefx_add_block"] || [name isEqual:@"axefx_remove_block"]) {
        BOOL adding=[name isEqual:@"axefx_add_block"];
        NSString *selected=before[@"context"][@"block"];
        NSUInteger count=0;for(NSDictionary *b in before[@"blocks"])if([b[@"selected"] boolValue])++count;
        BOOL empty=[selected hasSuffix:@": Empty"];
        NSNumber *effect=args[@"effect_id"];
        NSString *typeName=args[@"effect_type"];NSString *typeFailure=nil;
        if(adding && typeName) {
            NSDictionary *type=nil;for(NSDictionary *t in effectTypes())if([typeName isKindOfClass:NSString.class] && [t[@"type"] caseInsensitiveCompare:typeName]==NSOrderedSame)type=t;
            NSMutableSet *used=[NSMutableSet set];for(NSDictionary *b in before[@"blocks"])if(b[@"effect_id"])[used addObject:b[@"effect_id"]];
            if(!type) typeFailure=@"Unknown effect_type; use a type from axefx_inspect.effect_catalog";
            else if(effect && ![type[@"instances"] containsObject:effect]) typeFailure=@"effect_id does not belong to effect_type";
            else if(!effect) {for(NSNumber *i in type[@"instances"])if(![used containsObject:i]){effect=i;break;}
                if(!effect) typeFailure=[NSString stringWithFormat:@"All %@ instances are already in the grid",type[@"type"]];}
        }
        if(adding && !typeName && !effect) typeFailure=@"Supply effect_type (from axefx_inspect.effect_catalog) or effect_id";
        NSInteger eid=adding && [effect isKindOfClass:NSNumber.class] ? [effect integerValue] : 0;
        if(count!=1 || (adding ? !empty : empty)) failure=@"Select exactly one empty cell for insertion or occupied cell for removal, then inspect again";
        if(adding && (![effect isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)effect)==CFBooleanGetTypeID() || effect.doubleValue!=eid || eid<1 || eid>65535))failure=@"Invalid effect_id";
        if(typeFailure)failure=typeFailure;
        if(![self.writer respondsToSelector:@selector(editBlockNode:effectID:failure:)] || ![self.writer respondsToSelector:@selector(nativeBlockEditingAvailable)] || ![self.writer nativeBlockEditingAvailable])failure=@"Native block editing is unavailable for this editor build";
        if(adding)for(NSDictionary *b in before[@"blocks"])if([b[@"effect_id"] isEqual:effect])failure=@"Effect instance already exists in the grid";
        target=[self find:nil label:selected ?: @"missing selected cell" nodes:nodes];
        if(!failure)accepted=[self.writer editBlockNode:target effectID:eid failure:&failure];
        verifyKind=@"grid_edit";wanted=@{@"cell":[[selected ?: @"" componentsSeparatedByString:@":"] firstObject],@"adding":@(adding),@"effect_id":@(eid)};
    } else if([name isEqual:@"axefx_set_parameter"]) {
        NSString *parameter=args[@"parameter"]; NSNumber *number=args[@"value"], *expected=args[@"expected_value"];
        for(id node in nodes) if([attr(node,@"role") isEqual:NSAccessibilitySliderRole] && [parameterName(labelOf(node)) isEqual:parameter]) {
            if(target) { failure=@"Parameter label is ambiguous"; break; } target=node;
        }
        NSNumber *current=displayNumber(target);
        if(!failure && (![number isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)number)==CFBooleanGetTypeID() || !std::isfinite(number.doubleValue) || ![expected isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)expected)==CFBooleanGetTypeID() || !std::isfinite(expected.doubleValue) ||
            !current || ![current isEqual:expected])) failure=@"Value or expected_value is invalid/stale";
        // Native path only: the knob's own effect/parameter IDs, the firmware
        // definition and the editor's Undo-aware command. Range is enforced there.
        if(!failure && target) accepted=[self.writer setDisplayValue:number.doubleValue forAccessibilityNode:target failure:&failure];
        if(!target && !failure) failure=@"Parameter not found on the selected block";
        restore=current;
        verifyKind=@"parameter";wanted=@{@"parameter":parameter ?: @"",@"value":number ?: NSNull.null};
    } else if([name isEqual:@"axefx_set_bypass"] || [name isEqual:@"axefx_select_channel"] || [name isEqual:@"axefx_select_scene"]) {
        NSString *label=nil;
        if([name isEqual:@"axefx_set_bypass"] && [args[@"bypassed"] isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)args[@"bypassed"])==CFBooleanGetTypeID()) { label=@"Bypass";wanted=args[@"bypassed"]; }
        if([name isEqual:@"axefx_select_channel"] && [@[@"A",@"B",@"C",@"D"] containsObject:args[@"channel"]]) { label=[@"Channel " stringByAppendingString:args[@"channel"]];wanted=@YES; }
        if([name isEqual:@"axefx_select_scene"] && [args[@"scene"] isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)args[@"scene"])!=CFBooleanGetTypeID() && [args[@"scene"] doubleValue]==[args[@"scene"] integerValue] && [args[@"scene"] integerValue]>=1 && [args[@"scene"] integerValue]<=8) {
            label=[NSString stringWithFormat:@"Scene %ld",[args[@"scene"] integerValue]];wanted=@YES;
        }
        if(label) target=[self find:NSAccessibilityButtonRole label:label nodes:nodes];
        NSNumber *current=boolOf(attr(target,@"value"));
        if([name isEqual:@"axefx_set_bypass"]) {
            NSString *block=before[@"context"][@"block"];
            if(!([block hasSuffix:@", Active"] || [block hasSuffix:@", Bypassed"]))
                failure=@"Selected block has no observed bypass state; not sent";
            else if(![self.writer respondsToSelector:@selector(setBypassed:forAccessibilityNode:failure:)])
                failure=@"Native bypass toggle is unavailable; not sent";
            else if(target && current) accepted=[self.writer setBypassed:[wanted boolValue] forAccessibilityNode:target failure:&failure];
            verifyKind=@"bypass";
        } else {
            accepted=target && current && ([current boolValue]==[wanted boolValue] || press(target));verifyKind=@"button";
        }
        wanted=@{@"label":label ?: @"",@"value":wanted ?: NSNull.null};
    } else if([name isEqual:@"axefx_name_scene"]) {
        NSString *value=args[@"name"];
        target=[self find:nil label:@"Scene Name" nodes:nodes];
        if([value isKindOfClass:NSString.class] && value.length && value.length<=32 && [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location==NSNotFound) accepted=editText(target,value,&failure);
        verifyKind=@"scene_name";wanted=value;
    } else { self.executing=NO;reply(errorResult(@"Unknown Axe-Fx tool"));return; }
    if(!accepted) { self.executing=NO;reply(errorResult(failure ?: @"Native editor control is unavailable or refused the operation"));return; }
    self.executing=YES;
    // Cache accepted operations immediately. Stop, context changes or a timeout
    // must not turn a retry into a second write.
    NSDictionary *pending=@{@"ok":@NO,@"status":@"sent_readback_pending",@"retry_write":@NO};
    self.completed[key]=@{@"name":name,@"arguments":args,@"result":pending};
    // Grid and cable edits round-trip through the device and Axe-Edit reloads
    // its grid model meanwhile, so poll until the readback settles (<= 4 s).
    BOOL polls=[verifyKind isEqual:@"grid_edit"] || [verifyKind isEqual:@"routing"];
    __block NSInteger attempt=0; __block void (^check)(void)=nil; __block __weak void (^again)(void)=nil;
    check=^{
        NSDictionary *after=[self inspect]; BOOL verified=NO;
        if([verifyKind isEqual:@"selected_block"]) verified=[after[@"context"][@"block"] isEqual:wanted];
        if([verifyKind isEqual:@"parameter"]) for(NSDictionary *parameter in after[@"parameters"])
            if([parameter[@"parameter"] isEqual:wanted[@"parameter"]] && [parameter[@"value"] isKindOfClass:NSNumber.class])
                verified=std::abs([parameter[@"value"] doubleValue]-[wanted[@"value"] doubleValue])<=displayTolerance(parameter[@"label"]);
        if([verifyKind isEqual:@"button"] || [verifyKind isEqual:@"bypass"]) {
            id fresh=[self find:NSAccessibilityButtonRole label:wanted[@"label"] nodes:[self nodes]];
            NSNumber *current=boolOf(attr(fresh,@"value"));
            verified=fresh && current && current.boolValue==[wanted[@"value"] boolValue];
            if([verifyKind isEqual:@"bypass"])
                verified=verified && [after[@"context"][@"block"] hasSuffix:([wanted[@"value"] boolValue] ? @", Bypassed" : @", Active")];
        }
        if([verifyKind isEqual:@"routing"]) {
            NSArray *actual=after[@"cables"];
            verified=[actual isKindOfClass:NSArray.class] && actual.count==[wanted count] && [[NSSet setWithArray:actual] isEqual:[NSSet setWithArray:wanted]] && [before[@"context"][@"grid"] isEqual:after[@"context"][@"grid"]];
        }
        if([verifyKind isEqual:@"grid_edit"]) {
            NSString *prefix=[wanted[@"cell"] stringByAppendingString:@":"];
            NSMutableArray *oldOther=[NSMutableArray array],*newOther=[NSMutableArray array];
            NSString *changed=nil;
            for(NSString *cell in before[@"context"][@"grid"])if(![cell hasPrefix:prefix])[oldOther addObject:cell];
            for(NSString *cell in after[@"context"][@"grid"])if([cell hasPrefix:prefix])changed=cell;else [newOther addObject:cell];
            id fresh=[self find:nil label:changed ?: @"missing cell" nodes:[self nodes]];
            NSNumber *actual=[self.writer respondsToSelector:@selector(effectIDForGridNode:)] ? [self.writer effectIDForGridNode:fresh] : nil;
            verified=[actual isEqual:wanted[@"effect_id"]] && changed && ([wanted[@"adding"] boolValue] ? ![changed hasSuffix:@": Empty"] : [changed hasSuffix:@": Empty"]) && [oldOther isEqual:newOther];
        }
        if([verifyKind isEqual:@"scene_name"]) verified=[after[@"context"][@"Scene Name"] isEqual:wanted];
        NSMutableArray *stableFields=[NSMutableArray arrayWithArray:@[@"Preset Number",@"Preset Name"]];
        if(![name isEqual:@"axefx_select_scene"]) [stableFields addObject:@"Scene Number"];
        if([name isEqual:@"axefx_set_parameter"] || [name isEqual:@"axefx_set_bypass"] || [name isEqual:@"axefx_name_scene"]) [stableFields addObjectsFromArray:@[@"block_identity",@"channel"]];
        for(NSString *field in stableFields) if(![(before[@"context"][field] ?: NSNull.null) isEqual:(after[@"context"][field] ?: NSNull.null)]) verified=NO;
        if(![after[@"connected"] boolValue])verified=NO;
        if(!verified && polls && authority() && ++attempt<16) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250*NSEC_PER_MSEC),dispatch_get_main_queue(),again);
            return;
        }
        self.executing=NO;
        NSString *status=!authority() ? @"stopped_after_send" : (verified ? @"ui_readback_verified" : @"sent_readback_unverified");
        // A native write whose editor readback disagrees is put back to the
        // value shown before the write (same verified conversion), then reported.
        if(!verified && restore && [verifyKind isEqual:@"parameter"]) {
            id node=nil; for(id candidate in [self nodes]) if([attr(candidate,@"role") isEqual:NSAccessibilitySliderRole] && [parameterName(labelOf(candidate)) isEqual:wanted[@"parameter"]]) node=candidate;
            NSString *restoreFailure=nil;
            status=node && [self.writer setDisplayValue:restore.doubleValue forAccessibilityNode:node failure:&restoreFailure] ? @"readback_mismatch_restore_sent" : @"readback_mismatch_restore_failed_use_undo";
        }
        NSMutableDictionary *result=[@{@"ok":@(verified && authority()),@"status":status,
            @"retry_write":@NO,@"before":before,@"after":after,@"verification_scope":@"axe_edit_ui",@"hardware_persistence_verified":@NO} mutableCopy];
        if(!verified) result[@"next_step"]=@"Call axefx_inspect. If the grid/cables now show the requested change, continue with the next step; do not resend this operation_id. If it is clearly absent and nothing else changed, retry with a new operation_id.";
        self.completed[key]=@{@"name":name,@"arguments":args,@"result":result};
        check=nil;
        reply(result);
    };
    again=check;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (polls ? 250 : 500)*NSEC_PER_MSEC),dispatch_get_main_queue(),check);
}
@end
