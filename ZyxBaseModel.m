//
//  ZyxBaseModel.m
//  EasyFMDB
//
//  Created by sytuzhouyong on 14-3-19.
//  Copyright (c) 2013年 sytuzhouyong. All rights reserved.
//

#import "ZyxBaseModel.h"
#import <objc/runtime.h>
#import "ZyxTypedef.h"
#import "ZyxMacro.h"
#import "ZyxFieldAttribute.h"
#import "ZyxFMDBManager.h"

#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/getsect.h>
#import <mach-o/dyld.h>

static NSArray<NSString *> * ReadConfiguration(char *section);

@implementation ZyxBaseModel {
    NSMutableArray *_updatedProperties;
    NSMutableArray *_updatedPropertiesExceptId;
    NSMutableArray *_watchedKeys;
    NSMutableSet *_updatedPropertiesSet;
    BOOL _observerEnabled;
}

+ (NSSet<NSString *> *)registedModels {
    static NSSet *registedModels = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSString *> *models = ReadConfiguration(kSegmentName);
        registedModels = [NSSet setWithArray:models];
        
    });
    return registedModels;
}

+ (NSArray<NSString *> *)ignoredProperties {
    return nil;
}

#pragma mark - Init

- (instancetype)init {
    return [self initWithObserverEnabledFlag:YES];
}

- (instancetype)initWithObserverEnabledFlag:(BOOL)observerEnabled {
    if (self = [super init]) {
        _observerEnabled = observerEnabled;
        _updatedProperties = [[NSMutableArray alloc] init];
        _updatedPropertiesExceptId = [[NSMutableArray alloc] init];
        _updatedPropertiesSet = [NSMutableSet set];
        _watchedKeys = [[NSMutableArray alloc] init];
        
        if (observerEnabled) {
            [self addWatchKeys];
        }
    }
    return self;
}
- (void)setObserverEnabled:(BOOL)observerEnabled {
    if (observerEnabled) {
        [self addWatchKeys];
    } else {
        [_updatedProperties removeAllObjects];
        [_updatedPropertiesExceptId removeAllObjects];
        [_updatedPropertiesSet removeAllObjects];
        [_watchedKeys removeAllObjects];
    }
}

- (instancetype)copyWithZone:(NSZone *)zone {
    id copy = [[[self class] alloc] init];
    if (copy) {
        [copy setId:_id];
    }
    return copy;
}

#pragma mark - KVO

- (void)addWatchKeys {
    NSDictionary *properties = [self.class propertiesDictionary];
    for (NSString *obj in properties.allKeys) {
        if (![[self.class ignoredProperties] containsObject:obj]) {
            [self addObserver:self forKeyPath:obj options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld context:nil];
            [_watchedKeys addObject:obj];
        }
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
//    id newValue = [change objectForKey:@"new"];
//    if (newValue != nil && ![newValue isKindOfClass:NSNull.class]) {
    if (![_updatedPropertiesSet containsObject:keyPath]) {
        [_updatedPropertiesSet addObject:keyPath];
        [_updatedProperties addObject:keyPath];
        if (![keyPath isEqualToString:@"id"]) {
            [_updatedPropertiesExceptId addObject:keyPath];
        }
    }
//    }
}

#pragma mark - Common database operation methods

- (BOOL)save {
    return [[ZyxFMDBManager sharedInstance] save:self];
}
- (BOOL)delete {
    return [[ZyxFMDBManager sharedInstance] delete:self];
}
- (BOOL)update {
    return [[ZyxFMDBManager sharedInstance] update:self];
}
- (NSArray *)query {
    return [[ZyxFMDBManager sharedInstance] query:self];
}

#pragma mark - Property Dictionary

+ (NSDictionary *)propertiesDictionary {
    static NSMutableDictionary *properties = nil;
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        properties = [[NSMutableDictionary alloc] initWithCapacity:8];
    });
    
    NSString *name = NSStringFromClass(self.class);
    NSDictionary *value = [properties objectForKey:name];
    if (value == nil) {
        value = [self.class fieldsAttributeDictInClass:self.class];
        properties[name] = value;
    }
    return value;
}

- (NSArray *)updatedProperties {
    return _updatedProperties;
}
- (NSArray *)updatedValues {
    NSMutableArray *values = [NSMutableArray array];
    for (NSString *key in _updatedProperties) {
        [values addObject:[self valueForKey:key]];
    }
    return values;
}
- (NSArray *)updatedPropertiesExceptId {
    return _updatedPropertiesExceptId;
}
- (NSArray *)updatedValuesExceptId {
    NSMutableArray *values = [NSMutableArray array];
    for (NSString *key in _updatedPropertiesExceptId) {
        [values addObject:[self valueForKey:key]];
    }
    return values;
}

#pragma mark - Util Function

+ (NSString *)sql {
    static NSMutableDictionary *sqlDictionary = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sqlDictionary = [[NSMutableDictionary alloc] initWithCapacity:8];
    });
    
    NSString *name = NSStringFromClass(self.class);
    NSMutableString *sql = [sqlDictionary objectForKey:name];
    if (sql == nil) {
        sql = [[NSMutableString alloc] initWithCapacity:1024];
        [sql appendString:@"create table "];
        [sql appendString:TABLE_NAME(self)];
        [sql appendString:@" (id integer primary key autoincrement, "];
        
        NSArray *properties = [ZyxBaseModel fieldsAttributeInClass:self.class];
        for (ZyxFieldAttribute *property in properties) {
            if ([property.name isEqualToString:@"id"])
                continue;
            
            NSString *field = [NSString stringWithFormat:@"%@ %@, ", property.nameInDB, [ZyxDataType stringWithDataType:property.type]];
            [sql appendString:field];
        }
        
        if ([sql hasSuffix:@", "]) {
            [sql deleteCharactersInRange:NSMakeRange(sql.length-2, 2)];
        }
        [sql appendString:@")"];
        
        sqlDictionary[name] = sql;
    }
    
    return sql;
}

// get all properties including inherited form super class
+ (NSDictionary *)fieldsAttributeDictInClass:(Class)class {
    NSMutableDictionary *props = [[NSMutableDictionary alloc] init];
    Class c = class;
    NSString *classString = NSStringFromClass(c);
    NSString *objectString = NSStringFromClass(NSObject.class);
    
    while (![classString isEqualToString:objectString]) {
        unsigned int outCount;
        objc_property_t *properties = class_copyPropertyList(c, &outCount);
        for (unsigned int i = 0; i<outCount; i++) {
            objc_property_t property = properties[i];
            
            // name
            const char *char_name = property_getName(property);
            NSString *propertyName = [NSString stringWithUTF8String:char_name];
            // ingore invalid property
            if ([[self.class ignoredProperties] containsObject:propertyName]) {
                continue;
            }
            
            // attr
            const char *char_attr = property_getAttributes(property);
            NSString *propertyAttr = [NSString stringWithUTF8String:char_attr];
            
            NSScanner *scanner = [[NSScanner alloc] initWithString:propertyAttr];
            if (![scanner scanString:@"T" intoString:NULL])
                continue;
            
            BOOL isBaseModel = NO;
            NSString *typeString;
            // 说明是objc类型
            if ([scanner scanString:@"@\"" intoString:NULL]) {
                [scanner scanUpToString:@"\"" intoString:&typeString];
                
                // 说明是用户自定义的类
                isBaseModel = [[self registedModels] containsObject:typeString];
            } else {
                [scanner scanUpToString:@"," intoString:&typeString];
            }
            
            ZyxFieldAttribute *p = [[ZyxFieldAttribute alloc] init];
            p.name = propertyName;
            p.nameInDB = [self propertyNameToDBName:propertyName isBaseModel:isBaseModel];
            p.className = isBaseModel ? typeString : @"";
            p.type = isBaseModel ? ZyxFieldTypeBaseModel : [self dataTypeWithString:typeString];
            p.isBaseModel = isBaseModel;
            props[propertyName] = p;
        }
        
        c = class_getSuperclass(c);
        classString = NSStringFromClass(c);
        free(properties);
    }
    return props;
}

/// array of all ZyxFieldAttribute object in Class, the same order with that declared in class
+ (NSArray *)fieldsAttributeInClass:(Class)class {
    NSMutableArray *array = [NSMutableArray arrayWithCapacity:16];
    
    Class c = class;
    NSString *classString = NSStringFromClass(c);
    NSString *objectString = NSStringFromClass(NSObject.class);
    
    NSDictionary *propertyDict = [class propertiesDictionary];
    
    while (![classString isEqualToString:objectString]) {
        unsigned int outCount;
        objc_property_t *properties = class_copyPropertyList(c, &outCount);
        for (unsigned int i = 0; i<outCount; i++) {
            objc_property_t property = properties[i];
            
            const char *char_name = property_getName(property);
            NSString *propertyName = [NSString stringWithUTF8String:char_name];
            if ([[c ignoredProperties] containsObject:propertyName]) {
                continue;
            }
            
            ZyxFieldAttribute *p = propertyDict[propertyName];
            [array addObject:p];
        }
        
        c = class_getSuperclass(c);
        classString = NSStringFromClass(c);
        free(properties);
    }
    
    return  array;
}

+ (NSString *)propertyNameToDBName:(NSString *)propertyName isBaseModel:(BOOL)isBaseModel {
    NSMutableString *dbName = [NSMutableString string];
    NSUInteger length = propertyName.length;
    
    for (NSUInteger i=0; i<length; i++) {
        unichar c = [propertyName characterAtIndex:i];
        if (c >= 'A' && c <= 'Z') {
            [dbName appendFormat:@"_%c", tolower(c)];
        } else {
            [dbName appendFormat:@"%c", c];
        }
    }
    
    if (isBaseModel) {
        [dbName appendString:@"_id"];
    }
    
    return dbName;
}

+ (NSString *)dbNameToPropertyName:(NSString *)dbName {
    NSArray *elements = [dbName componentsSeparatedByString:@"_"];
    NSMutableString *propertyName = [NSMutableString stringWithString:elements.firstObject];
    if (elements.count < 2) {
        return propertyName;
    }
    
    // 说明property是ZyxBaseModel类型
    if ([dbName hasSuffix:@"_id"]) {
        return [dbName substringToIndex:dbName.length - 3];
    }
    
    for (NSUInteger i=1; i<elements.count; i++) {
        NSString *element = elements[i];
        [propertyName appendString:[element capitalizedString]];
    }
    return propertyName;
}

#pragma mark -

+ (ZyxFieldType)dataTypeWithString:(NSString *)typeString {
//    NSLog(@"type string : %@", typeString);
    const char *str = typeString.UTF8String;
    
    if (strcmp(str, @encode(bool)) == 0)            return ZyxFieldTypeBOOL;
    if (strcmp(str, @encode(BOOL)) == 0)            return ZyxFieldTypeBOOL;
    if (strcmp(str, @encode(NSInteger)) == 0)       return ZyxFieldTypeNSInteger;
    if (strcmp(str, @encode(NSUInteger)) == 0)      return ZyxFieldTypeNSUInteger;
    if (strcmp(str, @encode(CGFloat)) == 0)         return ZyxFieldTypeCGFloat;
    if (strcmp(str, @encode(int)) == 0)             return ZyxFieldTypeNSInteger;
    if (strcmp(str, @encode(short)) == 0)           return ZyxFieldTypeNSInteger;
    if (strcmp(str, @encode(unsigned)) == 0)        return ZyxFieldTypeNSUInteger;
    if (strcmp(str, @encode(long)) == 0)            return ZyxFieldTypeNSInteger;
    if (strcmp(str, @encode(long long int)) == 0)   return ZyxFieldTypeNSInteger;
    if (strcmp(str, @encode(unsigned long)) == 0)   return ZyxFieldTypeNSUInteger;
    if (strcmp(str, @encode(unsigned long long int)) == 0)   return ZyxFieldTypeNSUInteger;
    if (strcmp(str, @encode(float)) == 0)           return ZyxFieldTypeCGFloat;
    if (strcmp(str, @encode(double)) == 0)          return ZyxFieldTypeCGFloat;
    if (strcmp(str, @encode(char)) == 0)            return ZyxFieldTypeNSInteger;
    if (strcmp(str, @"NSDate".UTF8String) == 0)     return ZyxFieldTypeNSDate;
    if (strcmp(str, @"NSString".UTF8String) == 0)   return ZyxFieldTypeNSString;

    LogWarning(@"oh no, unrecognized data type : %s", str);
    return ZyxFieldTypeUnkonw;
}

#pragma mark - dealloc

- (void)dealloc {
    for (NSString *key in _watchedKeys) {
        [self removeObserver:self forKeyPath:key context:nil];
    }
}

+ (void)logType {
    NSLog(@"char: %s", @encode(char));
    NSLog(@"BOOL : %s", @encode(BOOL));
    
    NSLog(@"NSInteger: %s", @encode(NSInteger));
    NSLog(@"NSUInteger: %s", @encode(NSUInteger));
    NSLog(@"CGFloat: %s", @encode(CGFloat));
    
    NSLog(@"NSString: %s", @encode(NSString));
    NSLog(@"NSDate: %s", @encode(NSDate));
}

#pragma mark - Message Forward
//- (BOOL)resolveInstanceMethod {
//    return NO;
//}
//
//- (id)forwardingTargetForSelector:(SEL)selector {
//    NSString *selectorString = NSStringFromSelector(selector);
//    NSLog(@"selector = %@", selectorString);
//    
//    do {
//        if (![selectorString hasPrefix:@"get"])
//            break;
//        
//        NSScanner *scanner = [NSScanner scannerWithString:selectorString];
//        if (![scanner scanString:@"get" intoString:NULL])
//            break;
//        NSString *upperString = nil;
//        if (![scanner scanCharactersFromSet:[NSCharacterSet uppercaseLetterCharacterSet] intoString:&upperString])
//            break;
//        
//        NSString *partKey = [selectorString substringFromIndex:scanner.scanLocation];
//        NSString *propertyKey = [NSString stringWithFormat:@"%@%@", upperString.lowercaseString, partKey];
//        
//        NSDictionary *propertiesDict = [self.class propertiesDictionary];
//        ZyxFieldAttribute *property = propertiesDict[propertyKey];
//        if (!property.isBaseModel)
//            break;
//        
//        //        NSUInteger attachedBaseModelId =
//    } while (FALSE);
//    
//    return self;
//}

@end


static NSArray<NSString *> * ReadConfiguration(char *section) {
    NSMutableArray *configs = [NSMutableArray array];
    
    Dl_info info;
    dladdr(ReadConfiguration, &info);
    
#ifndef __LP64__
    // const struct mach_header *mhp = _dyld_get_image_header(0); // both works as below line
    const struct mach_header *mhp = (struct mach_header *)info.dli_fbase;
    unsigned long size = 0;
    // 找到之前存储的数据段(Module找BeehiveMods段 和 Service找BeehiveServices段)的一片内存
    uint32_t *memory = (uint32_t*)getsectiondata(mhp, "__DATA", section, &size);
#else /* defined(__LP64__) */
    const struct mach_header_64 *mhp = (struct mach_header_64 *)info.dli_fbase;
    unsigned long size = 0;
    uint64_t *memory = (uint64_t*)getsectiondata(mhp, "__DATA", section, &size); // memeory 指向的内容依旧是指针
#endif /* defined(__LP64__) */
    
    // 把特殊段里面的数据都转换成字符串存入数组中
    for (int idx = 0; idx < size/sizeof(void *); ++idx){
        char *string = (char*)memory[idx];
        NSString *str = [NSString stringWithUTF8String:string];
        if (!str)
            continue;
        
        NSLog(@"config = %@", str);
        [configs addObject:str];
    }
    
    return configs;
}
