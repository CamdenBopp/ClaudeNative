// VoiceOver probe: isolates how iOS VoiceOver finds link and custom rotors. See docs/accessibility/LINKS-ROTOR.md.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import <dlfcn.h>
typedef const char *(*EncFn)(Protocol *, SEL, BOOL, BOOL);
static NSString *Mode(void) { return [NSUserDefaults.standardUserDefaults stringForKey:@"mode"] ?: @"plain"; }
static void Log(NSString *s) { NSLog(@"PROBE %@", s); }

static void ScanEncodings(void) {
    unsigned n = 0; Protocol * __unsafe_unretained *ps = objc_copyProtocolList(&n);
    int hits = 0;
    EncFn _protocol_getMethodTypeEncoding = (EncFn)dlsym(RTLD_DEFAULT, "_protocol_getMethodTypeEncoding");
    if (!_protocol_getMethodTypeEncoding) { Log(@"ENC dlsym failed"); return; }
    for (unsigned i = 0; i < n; i++) {
        for (int req = 0; req < 2; req++) for (int inst = 0; inst < 2; inst++) {
            unsigned m = 0; struct objc_method_description *ds = protocol_copyMethodDescriptionList(ps[i], req, inst, &m);
            for (unsigned j = 0; j < m; j++) {
                const char *ext = _protocol_getMethodTypeEncoding(ps[i], ds[j].name, req, inst);
                if (ext && strchr(ext, '!')) {
                    hits++;
                    Log([NSString stringWithFormat:@"ENC %s %c[%s] %s", protocol_getName(ps[i]), inst ? '-' : '+', sel_getName(ds[j].name), ext]);
                }
            }
            free(ds);
        }
    }
    // Sanity check that the extended-encoding lookup works at all, so "0 hits" means something.
    int withExt = 0;
    for (unsigned i = 0; i < n; i++) {
        unsigned m = 0; struct objc_method_description *ds = protocol_copyMethodDescriptionList(ps[i], YES, YES, &m);
        if (m && _protocol_getMethodTypeEncoding(ps[i], ds[0].name, YES, YES)) withExt++;
        free(ds);
    }
    // The protocol ipsw 3.1.660 crashes on when class-dumping UIKitCore from the iOS 27.0 (24A434) simulator cache.
    Protocol *afd = objc_getProtocol("AFDictationDelegate");
    for (int req = 0; afd && req < 2; req++) { unsigned m = 0; struct objc_method_description *ds = protocol_copyMethodDescriptionList(afd, req, YES, &m);
        for (unsigned j = 0; j < m; j++) Log([NSString stringWithFormat:@"AFD %s %s | %s | %s", req ? "req" : "opt", sel_getName(ds[j].name), ds[j].types, _protocol_getMethodTypeEncoding(afd, ds[j].name, req, YES) ?: "(null)"]);
        free(ds); }
    Log([NSString stringWithFormat:@"ENC protocols with extended types=%d", withExt]);
    free(ps);
    Log([NSString stringWithFormat:@"ENC scanned %u protocols, %d encodings contain '!'", n, hits]);
}

@interface ProbeView : UIView
@property (nonatomic, strong) NSArray<UIAccessibilityElement *> *leaves;
@end
@implementation ProbeView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.systemBackgroundColor;
        NSArray *labels = @[@"Paragraph one", @"Example link", @"Paragraph two", @"Second link"];
        NSMutableArray *leaves = [NSMutableArray array];
        for (NSUInteger i = 0; i < labels.count; i++) {
            UIAccessibilityElement *e = [[UIAccessibilityElement alloc] initWithAccessibilityContainer:self];
            e.accessibilityLabel = labels[i];
            e.accessibilityTraits = [labels[i] hasSuffix:@"link"] ? UIAccessibilityTraitLink : UIAccessibilityTraitStaticText;
            e.accessibilityFrameInContainerSpace = CGRectMake(20, 20 + i * 60, frame.size.width - 40, 44);
            [leaves addObject:e];
        }
        self.leaves = leaves;
        self.accessibilityElements = leaves;
    }
    return self;
}
- (void)drawRect:(CGRect)rect {
    for (UIAccessibilityElement *e in self.leaves) {
        UIColor *c = (e.accessibilityTraits & UIAccessibilityTraitLink) ? UIColor.linkColor : UIColor.labelColor;
        [e.accessibilityLabel drawInRect:e.accessibilityFrameInContainerSpace withAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:20], NSForegroundColorAttributeName: c}];
    }
}
- (UIAccessibilityCustomRotor *)rotorNamed:(NSString *)name {
    __weak ProbeView *weakSelf = self;
    UIAccessibilityCustomRotorSearch search = ^UIAccessibilityCustomRotorItemResult *(UIAccessibilityCustomRotorSearchPredicate *p) {
        NSArray *links = [weakSelf.leaves filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(UIAccessibilityElement *e, id b) { return (e.accessibilityTraits & UIAccessibilityTraitLink) != 0; }]];
        id target = p.currentItem.targetElement; NSInteger cur = [weakSelf.leaves indexOfObject:target];
        UIAccessibilityElement *found = nil;
        if (p.searchDirection == UIAccessibilityCustomRotorDirectionNext) {
            for (UIAccessibilityElement *e in links) if (cur == NSNotFound || (NSInteger)[weakSelf.leaves indexOfObject:e] > cur) { found = e; break; }
        } else {
            for (UIAccessibilityElement *e in links.reverseObjectEnumerator) if (cur == NSNotFound || (NSInteger)[weakSelf.leaves indexOfObject:e] < cur) { found = e; break; }
        }
        Log([NSString stringWithFormat:@"SEARCH rotor=%@ dir=%ld from=%@ -> %@", name ?: @"system-link", (long)p.searchDirection, [(id)target accessibilityLabel], found.accessibilityLabel]);
        return found ? [[UIAccessibilityCustomRotorItemResult alloc] initWithTargetElement:found targetRange:nil] : nil;
    };
    return name ? [[UIAccessibilityCustomRotor alloc] initWithName:name itemSearchBlock:search]
                : [[UIAccessibilityCustomRotor alloc] initWithSystemType:UIAccessibilityCustomSystemRotorTypeLink itemSearchBlock:search];
}
@end

@interface VC : UIViewController
@end
@implementation VC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    NSString *mode = Mode();
    CGRect f = CGRectMake(0, 120, self.view.bounds.size.width, 300);
    if ([mode isEqualToString:@"textview"]) {
        UITextView *tv = [[UITextView alloc] initWithFrame:CGRectInset(f, 20, 0)];
        NSMutableAttributedString *s = [[NSMutableAttributedString alloc] initWithString:@"Paragraph one. Example link. Paragraph two. Second link." attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:20], NSForegroundColorAttributeName: UIColor.labelColor}];
        [s addAttribute:NSLinkAttributeName value:[NSURL URLWithString:@"https://example.com/a"] range:[s.string rangeOfString:@"Example link"]];
        [s addAttribute:NSLinkAttributeName value:[NSURL URLWithString:@"https://example.com/b"] range:[s.string rangeOfString:@"Second link"]];
        tv.attributedText = s; tv.editable = NO;
        [self.view addSubview:tv];
        return;
    }
    ProbeView *pv = [[ProbeView alloc] initWithFrame:f];
    [self.view addSubview:pv];
    if ([mode isEqualToString:@"container"]) pv.accessibilityCustomRotors = @[[pv rotorNamed:nil]];
    if ([mode isEqualToString:@"leaf"]) { NSArray *r = @[[pv rotorNamed:nil]]; for (UIAccessibilityElement *e in pv.leaves) e.accessibilityCustomRotors = r; }
    if ([mode isEqualToString:@"both"]) { NSArray *r = @[[pv rotorNamed:nil]]; pv.accessibilityCustomRotors = r; for (UIAccessibilityElement *e in pv.leaves) e.accessibilityCustomRotors = r; }
    if ([mode isEqualToString:@"mixed"]) { pv.accessibilityCustomRotors = @[[pv rotorNamed:nil]]; NSArray *r = @[[pv rotorNamed:@"Leaf rotor"]]; for (UIAccessibilityElement *e in pv.leaves) e.accessibilityCustomRotors = r; }
    if ([mode isEqualToString:@"named-container"]) pv.accessibilityCustomRotors = @[[pv rotorNamed:@"Message links"]];
    if ([mode isEqualToString:@"vc"]) self.view.accessibilityCustomRotors = @[[pv rotorNamed:nil]];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        for (NSString *cn in @[@"NSObject", @"UIView", @"UIAccessibilityElement", @"UIResponder"]) {
            unsigned mc = 0; Method *ms = class_copyMethodList(NSClassFromString(cn), &mc);
            for (unsigned k = 0; k < mc; k++) { const char *sn = sel_getName(method_getName(ms[k]));
                if (strcasestr(sn, "rotor")) { Dl_info di; dladdr((void *)method_getImplementation(ms[k]), &di);
                    Log([NSString stringWithFormat:@"METHOD %@ %s imp=%p image=%s sym=%s", cn, sn, (void *)method_getImplementation(ms[k]), di.dli_fname ? strrchr(di.dli_fname, '/') + 1 : "?", di.dli_sname ?: "?"]); } }
            free(ms);
        }
        SEL q = NSSelectorFromString(@"_iosAccessibilityAttributeValue:");
        for (UIAccessibilityElement *e in pv.leaves) {
            id v = [e respondsToSelector:q] ? ((id (*)(id, SEL, long))objc_msgSend)(e, q, 0x850) : @"<no _iosAccessibilityAttributeValue:>";
            Log([NSString stringWithFormat:@"ATTR2128 leaf=%@ own=%lu value=%@", e.accessibilityLabel, (unsigned long)e.accessibilityCustomRotors.count, v]);
        }
    });
}
@end

@interface SD : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
@implementation SD
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)o {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [VC new];
    [self.window makeKeyAndVisible];
}
@end

@interface AD : UIResponder <UIApplicationDelegate>
@end
@implementation AD
- (BOOL)application:(UIApplication *)a didFinishLaunchingWithOptions:(NSDictionary *)o {
    Log([NSString stringWithFormat:@"mode=%@", Mode()]);
    if ([Mode() isEqualToString:@"scan"]) ScanEncodings();
    return YES;
}
@end

int main(int argc, char *argv[]) { @autoreleasepool { return UIApplicationMain(argc, argv, nil, @"AD"); } }
