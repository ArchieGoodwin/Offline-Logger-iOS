//
//  OLManager.m
//  OfflineLogger
//
//  Created by Aaron Parecki on 10/21/13.
//  Copyright (c) 2013 Esri. All rights reserved.
//

#import "OLManager.h"
#import "LOLDatabase.h"
#import "AFHTTPSessionManager.h"

@interface OLManager()

@property (strong, nonatomic) CLLocationManager *locationManager;
@property (strong, nonatomic) CMMotionActivityManager *motionActivityManager;
@property (strong, nonatomic) CMStepCounter *stepCounter;

@property (strong, nonatomic) CLLocation *lastLocation;
@property (strong, nonatomic) CMMotionActivity *lastMotion;
@property (strong, nonatomic) NSNumber *lastStepCount;
@property (strong, nonatomic) NSDate *lastSentDate;

@property (strong, nonatomic) LOLDatabase *db;

@end

@implementation OLManager

static NSString *const OLLocationQueueName = @"OLLocationQueue";
static NSString *const OLStepCountQueueName = @"OLStepCountQueue";

AFHTTPSessionManager *_httpClient;

+ (OLManager *)sharedManager {
    static OLManager *_instance = nil;
    
    @synchronized (self) {
        if (_instance == nil) {
            _instance = [[self alloc] init];

            _instance.db = [[LOLDatabase alloc] initWithPath:[self cacheDatabasePath]];
            _instance.db.serializer = ^(id object){
                return [self dataWithJSONObject:object error:NULL];
            };
            _instance.db.deserializer = ^(NSData *data) {
                return [self objectFromJSONData:data error:NULL];
            };

            NSURL *endpoint = [NSURL URLWithString:[[NSUserDefaults standardUserDefaults] stringForKey:OLAPIEndpointDefaultsName]];
            
            _httpClient = [[AFHTTPSessionManager manager] initWithBaseURL:[NSURL URLWithString:[NSString stringWithFormat:@"%@://%@", endpoint.scheme, endpoint.host]]];
            _httpClient.requestSerializer = [AFJSONRequestSerializer serializer];
            _httpClient.responseSerializer = [AFJSONResponseSerializer serializer];
        }
    }
    
    return _instance;
}

#pragma mark LOLDB

+ (NSString *)cacheDatabasePath
{
	NSString *caches = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) objectAtIndex:0];
	return [caches stringByAppendingPathComponent:@"OLLoggerCache.sqlite"];
}

+ (id)objectFromJSONData:(NSData *)data error:(NSError **)error;
{
    return [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingAllowFragments error:error];
}

+ (NSData *)dataWithJSONObject:(id)object error:(NSError **)error;
{
    return [NSJSONSerialization dataWithJSONObject:object options:0 error:error];
}

#pragma mark -

+ (NSDate *)last24Hours {
    return [NSDate dateWithTimeIntervalSinceNow:-86400.0];
}

- (CLLocationManager *)locationManager {
    if (!_locationManager) {
        _locationManager = [[CLLocationManager alloc] init];
        _locationManager.delegate = self;
        _locationManager.desiredAccuracy = kCLLocationAccuracyBest;
        _locationManager.distanceFilter = 1;
    }
    
    return _locationManager;
}

- (CMMotionActivityManager *)motionActivityManager {
    if (!_motionActivityManager) {
        _motionActivityManager = [[CMMotionActivityManager alloc] init];
    }
    
    return _motionActivityManager;
}

- (CMStepCounter *)stepCounter {
    if (!_stepCounter) {
        _stepCounter = [[CMStepCounter alloc] init];
    }
    
    return _stepCounter;
}

- (void)startAllUpdates {
    [self.locationManager startUpdatingLocation];
    [self.locationManager startUpdatingHeading];
    if(CMMotionActivityManager.isActivityAvailable) {
        [self.motionActivityManager startActivityUpdatesToQueue:[NSOperationQueue mainQueue] withHandler:^(CMMotionActivity *activity) {
            [[NSNotificationCenter defaultCenter] postNotificationName:OLNewDataNotification object:self];
            self.lastMotion = activity;
        }];
    }
    if(CMStepCounter.isStepCountingAvailable) {
        // Request step count updates every 5 steps, but don't use the step count reported because then I'd have to keep track of the time I started counting steps. Instead, query the step API for the last hour's worth of steps.
        [self.stepCounter startStepCountingUpdatesToQueue:[NSOperationQueue mainQueue]
                                                 updateOn:5
                                              withHandler:^(NSInteger numberOfSteps, NSDate *timestamp, NSError *error) {
            [self queryStepCount:nil];
        }];
    }
}

- (void)stopAllUpdates {
    [self.locationManager stopUpdatingHeading];
    [self.locationManager stopUpdatingLocation];
    if(CMMotionActivityManager.isActivityAvailable) {
        [self.motionActivityManager stopActivityUpdates];
        self.lastMotion = nil;
    }
}

- (void)queryStepCount:(void(^)(NSInteger numberOfSteps, NSError *error))callback {
    [self.stepCounter queryStepCountStartingFrom:[OLManager last24Hours]
                                              to:[NSDate date]
                                         toQueue:[NSOperationQueue mainQueue]
                                     withHandler:^(NSInteger numberOfSteps, NSError *error) {
                                         self.lastStepCount = [NSNumber numberWithInteger:numberOfSteps];
                                         if(callback) {
                                             callback(numberOfSteps, error);
                                         }
                                     }];
}

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray *)locations {
    [[NSNotificationCenter defaultCenter] postNotificationName:OLNewDataNotification object:self];
    self.lastLocation = (CLLocation *)locations[0];
    
    // Queue the point in the database
	[self.db accessCollection:OLLocationQueueName withBlock:^(id<LOLDatabaseAccessor> accessor) {

        NSMutableArray *motion = [[NSMutableArray alloc] init];
        CMMotionActivity *activity = [OLManager sharedManager].lastMotion;
        if(activity.walking)
            [motion addObject:@"walking"];
        if(activity.running)
            [motion addObject:@"running"];
        if(activity.automotive)
            [motion addObject:@"driving"];
        if(activity.stationary)
            [motion addObject:@"stationary"];

        for(int i=0; i<locations.count; i++) {
            CLLocation *loc = locations[i];
            NSDictionary *update = @{
                @"timestamp": [NSString stringWithFormat:@"%d", (int)round([loc.timestamp timeIntervalSince1970])],
                @"latitude": [NSString stringWithFormat:@"%f", loc.coordinate.latitude],
                @"longitude": [NSString stringWithFormat:@"%f", loc.coordinate.longitude],
                @"altitude": [NSString stringWithFormat:@"%d", (int)round(loc.altitude)],
                @"speed": [NSString stringWithFormat:@"%d", (int)round(loc.speed)],
                @"horizontal_accuracy": [NSString stringWithFormat:@"%d", (int)round(loc.horizontalAccuracy)],
                @"vertical_accuracy": [NSString stringWithFormat:@"%d", (int)round(loc.verticalAccuracy)],
                @"motion": motion
            };
//            NSLog(@"Storing location update %@, for key: %@", update, [update objectForKey:@"timestamp"]);
            [accessor setDictionary:update forKey:[update objectForKey:@"timestamp"]];
        }
        
	}];
    
}

- (void)numberOfLocationsInQueue:(void(^)(long num))callback {
    [self.db accessCollection:OLLocationQueueName withBlock:^(id<LOLDatabaseAccessor> accessor) {
        [accessor countObjectsUsingBlock:callback];
    }];
}

- (void)sendQueueNow {
    NSMutableSet *syncedUpdates = [NSMutableSet set];
    NSMutableArray *locationUpdates = [NSMutableArray array];

    [self.db accessCollection:OLLocationQueueName withBlock:^(id<LOLDatabaseAccessor> accessor) {

        [accessor enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *object) {
            [syncedUpdates addObject:key];
            [locationUpdates addObject:object];
            return (BOOL)(locationUpdates.count >= 100); // N points per batch
        }];

    }];

    NSDictionary *postData = @{@"locations": locationUpdates};
    
    NSString *endpoint = [[NSUserDefaults standardUserDefaults] stringForKey:OLAPIEndpointDefaultsName];
    NSLog(@"Endpoint: %@", endpoint);
    NSLog(@"Updates in post: %lu", (unsigned long)locationUpdates.count);
    
    [_httpClient POST:endpoint parameters:postData success:^(NSURLSessionDataTask *task, id responseObject) {
        NSLog(@"Response: %@", responseObject);

        if([responseObject objectForKey:@"error"]) {
            [self notify:[responseObject objectForKey:@"error"] withTitle:@"Error"];
        } else {
            self.lastSentDate = NSDate.date;
            
            [self.db accessCollection:OLLocationQueueName withBlock:^(id<LOLDatabaseAccessor> accessor) {
                for(NSString *key in syncedUpdates) {
                    [accessor removeDictionaryForKey:key];
                }
            }];
        }
        
    } failure:^(NSURLSessionDataTask *task, NSError *error) {
        NSLog(@"Error: %@", error);
        [self notify:error.description withTitle:@"Error"];
    }];
    
}

- (void)notify:(NSString *)message withTitle:(NSString *)title
{
    if([[UIApplication sharedApplication] applicationState] == UIApplicationStateActive) {
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:title message:message delegate:self cancelButtonTitle:@"Close" otherButtonTitles:nil];
        [alert show];
    } else {
        UILocalNotification* localNotification = [[UILocalNotification alloc] init];
        localNotification.fireDate = [NSDate dateWithTimeIntervalSinceNow:1];
        localNotification.alertBody = [NSString stringWithFormat:@"%@: %@", title, message];
        localNotification.timeZone = [NSTimeZone defaultTimeZone];
        [[UIApplication sharedApplication] scheduleLocalNotification:localNotification];
    }
}


@end
