//
//  RKObjectMapper.m
//  RestKit
//
//  Created by Blake Watters on 5/6/11.
//  Copyright 2011 Two Toasters. All rights reserved.
//

#import "RKObjectMapper.h"
#import "Errors.h"

@interface RKObjectMapper (Private)

- (id)mapObject:(id)mappableObject atKeyPath:keyPath usingMapping:(RKObjectMapping*)mapping;
- (NSArray*)mapCollection:(NSArray*)mappableObjects atKeyPath:(NSString*)keyPath usingMapping:(RKObjectMapping*)mapping;
- (id)mapFromObject:(id)mappableObject toObject:(id)destinationObject atKeyPath:keyPath usingMapping:(RKObjectMapping*)mapping;

@end

// TODO: Move these into the object mapping operation class
//@implementation RKObjectMapperTracingDelegate
//
//- (void)objectMappingOperation:(RKObjectMappingOperation *)operation didFindMapping:(RKObjectAttributeMapping *)elementMapping forKeyPath:(NSString *)keyPath {
//    RKLOG_MAPPING(0, @"Found mapping for keyPath '%@': %@", keyPath, elementMapping);
//}
//
//- (void)objectMappingOperation:(RKObjectMappingOperation *)operation didNotFindMappingForKeyPath:(NSString *)keyPath {
//    RKLOG_MAPPING(0, @"Unable to find mapping for keyPath '%@'", keyPath);
//}
//
//- (void)objectMappingOperation:(RKObjectMappingOperation *)operation didSetValue:(id)value forKeyPath:(NSString *)keyPath usingMapping:(RKObjectAttributeMapping*)mapping {
//    RKLOG_MAPPING(0, @"Set '%@' to '%@' on object %@", keyPath, value, operation.destinationObject);
//}
//
//- (void)objectMapper:(RKObjectMapper *)objectMapper didAddError:(NSError *)error {
//    RKLOG_MAPPING(0, @"Object mapper encountered error: %@", [error localizedDescription]);
//}
//
//- (void)objectMappingOperation:(RKObjectMappingOperation *)operation didFailWithError:(NSError*)error {
//    RKLOG_MAPPING(0, @"Object mapping operation failed with error: %@", [error localizedDescription]);
//}
//
//@end

@implementation RKObjectMapper

@synthesize sourceObject = _sourceObject;
@synthesize targetObject = _targetObject;
@synthesize delegate =_delegate;
@synthesize mappingProvider = _mappingProvider;
@synthesize errors = _errors;

+ (id)mapperWithObject:(id)object mappingProvider:(RKObjectMappingProvider*)mappingProvider {
    return [[[self alloc] initWithObject:object mappingProvider:mappingProvider] autorelease];
}

- (id)initWithObject:(id)object mappingProvider:(RKObjectMappingProvider*)mappingProvider {
    self = [super init];
    if (self) {
        _sourceObject = [object retain];
        _mappingProvider = mappingProvider;
        _errors = [NSMutableArray new];
    }
    
    return self;
}

- (void)dealloc {
    [_sourceObject release];
    [_errors release];
    [super dealloc];
}

- (id)createInstanceOfClassForMapping:(Class)mappableClass {
    // TODO: Believe we want this to consult the delegate? Or maybe the provider? objectForMappingWithClass:atKeyPath:
    if (mappableClass) {
        return [[mappableClass new] autorelease];
    }
    
    return nil;
}

#pragma mark - Errors

- (NSUInteger)errorCount {
    return [self.errors count];
}

- (void)addError:(NSError*)error {
    NSAssert(error, @"Cannot add a nil error");
    [_errors addObject:error];
    
    if ([self.delegate respondsToSelector:@selector(objectMapper:didAddError:)]) {
        [self.delegate objectMapper:self didAddError:error];
    }
    // TODO: Log error
}

- (void)addErrorWithCode:(RKObjectMapperErrorCode)errorCode message:(NSString*)errorMessage keyPath:(NSString*)keyPath userInfo:(NSDictionary*)otherInfo {
    NSMutableDictionary* userInfo = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                     errorMessage, NSLocalizedDescriptionKey,
                                     @"RKObjectMapperKeyPath", keyPath ? keyPath : (NSString*) [NSNull null],
                                     nil];
    [userInfo addEntriesFromDictionary:otherInfo];
    NSError* error = [NSError errorWithDomain:RKRestKitErrorDomain code:errorCode userInfo:userInfo];
    [self addError:error];
}

- (void)addErrorForUnmappableKeyPath:(NSString*)keyPath {
    NSString* errorMessage = [NSString stringWithFormat:@"Could not find an object mapping for keyPath: %@", keyPath];
    [self addErrorWithCode:RKObjectMapperErrorObjectMappingNotFound message:errorMessage keyPath:keyPath userInfo:nil];
}

- (BOOL)isNullCollection:(id)object {
    if ([object respondsToSelector:@selector(countForObject:)]) {
        return ([object countForObject:[NSNull null]] == [object count]);
    }
    
    return NO;
}

#pragma mark - Mapping Primitives

- (id)mapObject:(id)mappableObject atKeyPath:(NSString*)keyPath usingMapping:(RKObjectMapping*)objectMapping {
    NSAssert([mappableObject respondsToSelector:@selector(setValue:forKeyPath:)], @"Expected self.object to be KVC compliant");
    id destinationObject = nil;
    
    if (self.targetObject) {
        // If we find a mapping for this type and keyPath, map the entire dictionary to the target object
        destinationObject = self.targetObject;
        if (objectMapping && NO == [[self.targetObject class] isSubclassOfClass:objectMapping.objectClass]) {
            NSString* errorMessage = [NSString stringWithFormat:
                                      @"Expected an object mapping for class of type '%@', provider returned one for '%@'", 
                                      NSStringFromClass([self.targetObject class]), NSStringFromClass(objectMapping.objectClass)];            
            [self addErrorWithCode:RKObjectMapperErrorObjectMappingTypeMismatch message:errorMessage keyPath:keyPath userInfo:nil];
            return nil;
        }
    } else {
        destinationObject = [self createInstanceOfClassForMapping:objectMapping.objectClass];
        // TODO: Check the type?
    }
    
    if (objectMapping && destinationObject) {
        return [self mapFromObject:mappableObject toObject:destinationObject atKeyPath:keyPath usingMapping:objectMapping];
    } else {
        // Attempted to map an object but couldn't find a mapping for the keyPath
        [self addErrorForUnmappableKeyPath:keyPath];
        return nil;
    }
    
    return nil;
}

- (NSArray*)mapCollection:(NSArray*)mappableObjects atKeyPath:(NSString*)keyPath usingMapping:(RKObjectMapping*)mapping {
    NSAssert(mappableObjects != nil, @"Cannot map without an collection of mappable objects");
    NSAssert(mapping != nil, @"Cannot map without a mapping to consult");
    // TODO: Assert on the type of mappableObjects?
    
    // Ensure we are mapping onto a mutable collection if there is a target
    if (self.targetObject && NO == [self.targetObject respondsToSelector:@selector(addObject:)]) {
        NSString* errorMessage = [NSString stringWithFormat:
                                  @"Cannot map a collection of objects onto a non-mutable collection. Unexpected target object type '%@'", 
                                  NSStringFromClass([self.targetObject class])];            
        [self addErrorWithCode:RKObjectMapperErrorObjectMappingTypeMismatch message:errorMessage keyPath:keyPath userInfo:nil];
        return nil;
    }
    
    // TODO: It should map arrays of arrays...
    NSMutableArray* mappedObjects = self.targetObject ? self.targetObject : [NSMutableArray arrayWithCapacity:[mappableObjects count]];
    for (id mappableObject in mappableObjects) {
        // TODO: Need to examine the type of elements and behave appropriately...
        // Believe this just goes away...
        if ([mappableObject isKindOfClass:[NSDictionary class]]) {
            id destinationObject = [self createInstanceOfClassForMapping:mapping.objectClass];
            NSObject* mappedObject = [self mapFromObject:mappableObject toObject:destinationObject atKeyPath:keyPath usingMapping:mapping];
            if (mappedObject) {
                [mappedObjects addObject:mappedObject];
            }
        } else {
            // TODO: Delegate method invocation here...
            RKFAILMAPPING();
        }
    }
    
    return mappedObjects;
}

// The workhorse of this entire process. Emits object loading operations
// TODO: This should probably just return a BOOL?
- (id)mapFromObject:(id)mappableObject toObject:(id)destinationObject atKeyPath:keyPath usingMapping:(RKObjectMapping*)mapping {
    NSAssert(destinationObject != nil, @"Cannot map without a target object to assign the results to");    
    NSAssert(mappableObject != nil, @"Cannot map without a collection of attributes");
    NSAssert(mapping != nil, @"Cannot map without an mapping");
    
    RKLOG_MAPPING(0, @"Asked to map source object %@ with mapping %@", sourceObject, mapping);
    if ([self.delegate respondsToSelector:@selector(objectMapper:willMapObject:fromObject:atKeyPath:usingMapping:)]) {
        [self.delegate objectMapper:self willMapObject:destinationObject fromObject:mappableObject atKeyPath:keyPath usingMapping:mapping];
    }
    
    NSError* error = nil;
    RKObjectMappingOperation* operation = [[RKObjectMappingOperation alloc] initWithSourceObject:mappableObject destinationObject:destinationObject objectMapping:mapping];
    BOOL success = [operation performMapping:&error];
    [operation release];
    
    if (success) {
        if ([self.delegate respondsToSelector:@selector(objectMapper:didMapObject:fromObject:atKeyPath:usingMapping:)]) {
            [self.delegate objectMapper:self didMapObject:destinationObject fromObject:mappableObject atKeyPath:keyPath usingMapping:mapping];
        }
    } else {
        if ([self.delegate respondsToSelector:@selector(objectMapper:didFailMappingObject:withError:fromObject:atKeyPath:usingMapping:)]) {
            [self.delegate objectMapper:self didFailMappingObject:destinationObject withError:error fromObject:mappableObject atKeyPath:keyPath usingMapping:mapping];
        }
        [self addError:error];
    }
    
    return destinationObject;
}

// Primary entry point for the mapper. 
- (RKObjectMappingResult*)performMapping {
    NSAssert(self.sourceObject != nil, @"Cannot perform object mapping without a source object to map from");
    NSAssert(self.mappingProvider != nil, @"Cannot perform object mapping without an object mapping provider");
    
    RKLOG_MAPPING(0, @"Self.object is %@", self.object);
    // TODO: Log if there is a target object...
    
    if ([self.delegate respondsToSelector:@selector(objectMapperWillBeginMapping:)]) {
        [self.delegate objectMapperWillBeginMapping:self];
    }
    
    // Perform the mapping
    NSMutableDictionary* results = [NSMutableDictionary dictionary];
    NSDictionary* keyPathsAndObjectMappings = [self.mappingProvider keyPathsAndObjectMappings];
    for (NSString* keyPath in keyPathsAndObjectMappings) {
        id mappingResult;
        id mappableValue;
        
        if ([self.delegate respondsToSelector:@selector(objectMapper:willAttemptMappingForKeyPath:)]) {
            [self.delegate objectMapper:self willAttemptMappingForKeyPath:keyPath];
        }
        // TODO: LOG this event
        
        if ([keyPath isEqualToString:@""]) {
            mappableValue = self.sourceObject;
        } else {
            mappableValue = [self.sourceObject valueForKeyPath:keyPath];
        }
        
        // Not found...
        if (mappableValue == nil || mappableValue == [NSNull null] || [self isNullCollection:mappableValue]) {
            NSLog(@"Not mappable, skipping... %@", mappableValue);
            
            if ([self.delegate respondsToSelector:@selector(objectMapper:didNotFindMappingForKeyPath:)]) {
                [self.delegate objectMapper:self didNotFindMappingForKeyPath:keyPath];
            }
            
            continue;
        }
        
        // Found something to map
        RKObjectMapping* objectMapping = [keyPathsAndObjectMappings objectForKey:keyPath];
        if ([self.delegate respondsToSelector:@selector(objectMapper:didFindMapping:forKeyPath:)]) {
            [self.delegate objectMapper:self didFindMapping:objectMapping forKeyPath:keyPath];
        }
        if ([mappableValue isKindOfClass:[NSArray class]] || [mappableValue isKindOfClass:[NSSet class]]) {
            // mapCollection:atKeyPath:usingMapping:
            mappingResult = [self mapCollection:mappableValue atKeyPath:keyPath usingMapping:objectMapping];
        } else {
            // mapObject:atKeyPath:usingMapping:
            mappingResult = [self mapObject:mappableValue atKeyPath:keyPath usingMapping:objectMapping];
        }
        
        if (mappingResult) {
            [results setObject:mappingResult forKey:keyPath];
        }
    }
    
    if ([self.delegate respondsToSelector:@selector(objectMapperDidFinishMapping:)]) {
        [self.delegate objectMapperDidFinishMapping:self];
    }
    
    
    if ([results count] == 0) {
        [self addErrorForUnmappableKeyPath:@""];
        return nil;
    }
    
    return [RKObjectMappingResult mappingResultWithDictionary:results];
}

@end
