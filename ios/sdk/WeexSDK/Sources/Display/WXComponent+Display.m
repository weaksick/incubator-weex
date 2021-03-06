/**
 * Created by Weex.
 * Copyright (c) 2016, Alibaba, Inc. All rights reserved.
 *
 * This source code is licensed under the Apache Licence 2.0.
 * For the full copyright and license information,please view the LICENSE file in the root directory of this source tree.
 */

#import "WXComponent+Display.h"
#import "WXComponent.h"
#import "WXComponent_internal.h"
#import "WXLayer.h"
#import "WXAssert.h"
#import "WXUtility.h"
#import "WXDisplayQueue.h"
#import "WXThreadSafeCounter.h"
#import "UIBezierPath+Weex.h"
#import "WXRoundedRect.h"
#import "WXSDKInstance.h"

#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation WXComponent (Display)

#pragma mark Public

- (void)setNeedsDisplay
{
    WXAssertMainThread();
    
    if (_compositingChild) {
        WXComponent *supercomponent = self.supercomponent;
        while (supercomponent) {
            if (supercomponent->_composite) {
                break;
            }
            supercomponent = supercomponent.supercomponent;
        }
        [supercomponent setNeedsDisplay];
    } else if (!_layer || _layer.frame.size.width ==0 || _layer.frame.size.height == 0) {
        return;
    } else {
        [_layer setNeedsDisplay];
    }
}

- (WXDisplayBlock)displayBlock
{
    WXDisplayBlock displayBlock = ^UIImage *(CGRect bounds, BOOL(^isCancelled)(void)) {
        if (isCancelled()) {
            return nil;
        }
        
        if (![self _needsDrawBorder]) {
            WXLogDebug(@"No need to draw border for %@", self.ref);
            WXPerformBlockOnMainThread(^{
                [self _resetNativeBorderRadius];
            });
            return nil;
        }
        
        return [self _borderImage];
    };
    
    return displayBlock;
}

- (WXDisplayCompletionBlock)displayCompletionBlock
{
    return nil;
}

#pragma mark Private

- (void)_willDisplayLayer:(CALayer *)layer
{
    WXAssertMainThread();
    
    if (_compositingChild) {
        // compsiting children need not draw layer
        return;
    }
    
    CGRect displayBounds = CGRectMake(0, 0, self.calculatedFrame.size.width, self.calculatedFrame.size.height);
    
    WXDisplayBlock displayBlock;
    if (_composite) {
        displayBlock = [self _compositeDisplayBlock];
    } else {
        displayBlock = [self displayBlock];
    }
    WXDisplayCompletionBlock completionBlock = [self displayCompletionBlock];
    
    if (!displayBlock) {
        if (completionBlock) {
            completionBlock(layer, NO);
        }
        return;
    }
    
    if (_async) {
        WXThreadSafeCounter *displayCounter = _displayCounter;
        int32_t displayValue = [displayCounter increase];
        BOOL (^isCancelled)() = ^BOOL(){
            return displayValue != displayCounter.value;
        };
        
        [WXDisplayQueue addBlock:^{
            if (isCancelled()) {
                if (completionBlock) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        completionBlock(layer, NO);
                    });
                }
                return;
            }
            
            UIImage *image = displayBlock(displayBounds, isCancelled);
            
            dispatch_async(dispatch_get_main_queue(), ^{
                if (isCancelled()) {
                    if (completionBlock) {
                        completionBlock(layer, NO);
                    }
                    return;
                }
                
                layer.contents = (id)(image.CGImage);
                
                if (completionBlock) {
                    completionBlock(layer, YES);
                }
            });
            
        }];
    } else {
        UIImage *image = displayBlock(displayBounds, ^BOOL(){
            return NO;
        });
        
        _layer.contents = (id)image.CGImage;
        
        if (completionBlock) {
            completionBlock(layer, YES);
        }
    }
}

- (WXDisplayBlock)_compositeDisplayBlock
{
    return ^UIImage* (CGRect bounds, BOOL(^isCancelled)(void)) {
        if (isCancelled()) {
            return nil;
        }
        NSMutableArray *displayBlocks = [NSMutableArray array];
        [self _collectDisplayBlocks:displayBlocks isCancelled:isCancelled];
        
        BOOL opaque = _layer.opaque && CGColorGetAlpha(_backgroundColor.CGColor) == 1.0f;
        
        UIGraphicsBeginImageContextWithOptions(bounds.size, opaque, 0.0);
        
        for (dispatch_block_t block in displayBlocks) {
            if (isCancelled()) {
                UIGraphicsEndImageContext();
                return nil;
            }
            block();
        }
        
        UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        
        return image;
    };
}

- (void)_collectDisplayBlocks:(NSMutableArray *)displayBlocks isCancelled:(BOOL(^)(void))isCancelled
{
    // compositingChild has no chance to applyPropertiesToView, so force updateNode
    //    if (_compositingChild) {
    //        if (_data) {
    //            dispatch_async(dispatch_get_main_queue(), ^{
    //                [self updateNode:_data];
    //            });
    //        }
    //    }
    
    UIColor *backgroundColor = _backgroundColor;
    BOOL clipsToBounds = _clipToBounds;
    CGRect frame = self.calculatedFrame;
    CGRect bounds = CGRectMake(0, 0, frame.size.width, frame.size.height);
    
    if (_composite) {
        frame.origin = CGPointMake(0, 0);
    }
    
    WXDisplayBlock displayBlock = [self displayBlock];
    
    BOOL shouldDisplay = displayBlock || backgroundColor || CGPointEqualToPoint(CGPointZero, frame.origin) == NO || clipsToBounds;
    
    if (shouldDisplay) {
        dispatch_block_t displayBlockToPush = ^{
            CGContextRef context = UIGraphicsGetCurrentContext();
            CGContextSaveGState(context);
            CGContextTranslateCTM(context, frame.origin.x, frame.origin.y);
            
            if (_compositingChild && clipsToBounds) {
                [[UIBezierPath bezierPathWithRect:bounds] addClip];
            }
            
            CGColorRef backgroundCGColor = backgroundColor.CGColor;
            if (backgroundColor && CGColorGetAlpha(backgroundCGColor) > 0.0) {
                CGContextSetFillColorWithColor(context, backgroundCGColor);
                CGContextFillRect(context, bounds);
            }
            
            if (displayBlock) {
                UIImage *image = displayBlock(bounds, isCancelled);
                if (image) {
                    [image drawInRect:bounds];
                }
            }
        };
        [displayBlocks addObject:[displayBlockToPush copy]];
    }
    
    for (WXComponent *component in self.subcomponents) {
        if (!isCancelled()) {
            [component _collectDisplayBlocks:displayBlocks isCancelled:isCancelled];
        }
    }
    
    if (shouldDisplay) {
        dispatch_block_t blockToPop = ^{
            CGContextRef context = UIGraphicsGetCurrentContext();
            CGContextRestoreGState(context);
        };
        [displayBlocks addObject:[blockToPop copy]];
    }
}

#pragma mark Border Drawing

- (UIImage *)_borderImage
{
    CGSize size = self.calculatedFrame.size;
    if (size.width <= 0 || size.height <= 0) {
        WXLogDebug(@"No need to draw border for %@, because width or height is zero", self.ref);
        return nil;
    }
    
    WXLogDebug(@"Begin to draw border for %@", self.ref);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
    CGContextRef context = UIGraphicsGetCurrentContext();
    
    [self _drawBorderWithContext:context size:size];
    
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    
    return image;
}

- (void)_drawBorderWithContext:(CGContextRef)context size:(CGSize)size
{
    CGRect rect = CGRectMake(0, 0, size.width, size.height);
    WXRoundedRect *borderRect = [[WXRoundedRect alloc] initWithRect:rect topLeft:_borderTopLeftRadius topRight:_borderTopRightRadius bottomLeft:_borderBottomLeftRadius bottomRight:_borderBottomRightRadius];
    // here is computed radii, do not use original style
    WXRadii *radii = borderRect.radii;
    CGFloat topLeft = radii.topLeft, topRight = radii.topRight, bottomLeft = radii.bottomLeft, bottomRight = radii.bottomRight;
    
    // fill background color
    if (_backgroundColor && CGColorGetAlpha(_backgroundColor.CGColor) > 0) {
        CGContextSetFillColorWithColor(context, _backgroundColor.CGColor);
        UIBezierPath *bezierPath = [UIBezierPath wx_bezierPathWithRoundedRect:rect topLeft:topLeft topRight:topRight bottomLeft:bottomLeft bottomRight:bottomRight];
        [bezierPath fill];
    }
    
    // Top
    if (_borderTopWidth > 0) {
        if(_borderTopStyle == WXBorderStyleDashed || _borderTopStyle == WXBorderStyleDotted){
            CGFloat lengths[2];
            lengths[0] = lengths[1] = (_borderTopStyle == WXBorderStyleDashed ? 3 : 1) * _borderTopWidth;
            CGContextSetLineDash(context, 0, lengths, sizeof(lengths) / sizeof(*lengths));
        } else{
            CGContextSetLineDash(context, 0, 0, 0);
        }
        CGContextSetLineWidth(context, _borderTopWidth);
        CGContextSetStrokeColorWithColor(context, _borderTopColor.CGColor);
        CGContextAddArc(context, size.width-topRight, topRight, topRight-_borderTopWidth/2, -M_PI_4+(_borderRightWidth>0?0:M_PI_4), -M_PI_2, 1);
        CGContextMoveToPoint(context, size.width-topRight, _borderTopWidth/2);
        CGContextAddLineToPoint(context, topLeft, _borderTopWidth/2);
        CGContextAddArc(context, topLeft, topLeft, topLeft-_borderTopWidth/2, -M_PI_2, -M_PI_2-M_PI_4-(_borderLeftWidth>0?0:M_PI_4), 1);
        CGContextStrokePath(context);
    }
    
    // Left
    if (_borderLeftWidth > 0) {
        if(_borderLeftStyle == WXBorderStyleDashed || _borderLeftStyle == WXBorderStyleDotted){
            CGFloat lengths[2];
            lengths[0] = lengths[1] = (_borderLeftStyle == WXBorderStyleDashed ? 3 : 1) * _borderLeftWidth;
            CGContextSetLineDash(context, 0, lengths, sizeof(lengths) / sizeof(*lengths));
        } else{
            CGContextSetLineDash(context, 0, 0, 0);
        }
        CGContextSetLineWidth(context, _borderLeftWidth);
        CGContextSetStrokeColorWithColor(context, _borderLeftColor.CGColor);
        CGContextAddArc(context, topLeft, topLeft, topLeft-_borderLeftWidth/2, -M_PI, -M_PI_2-M_PI_4+(_borderTopWidth > 0?0:M_PI_4), 0);
        CGContextMoveToPoint(context, _borderLeftWidth/2, topLeft);
        CGContextAddLineToPoint(context, _borderLeftWidth/2, size.height-bottomLeft);
        CGContextAddArc(context, bottomLeft, size.height-bottomLeft, bottomLeft-_borderLeftWidth/2, M_PI, M_PI-M_PI_4-(_borderBottomWidth>0?0:M_PI_4), 1);
        CGContextStrokePath(context);
    }
    
    // Bottom
    if (_borderBottomWidth > 0) {
        if(_borderBottomStyle == WXBorderStyleDashed || _borderBottomStyle == WXBorderStyleDotted){
            CGFloat lengths[2];
            lengths[0] = lengths[1] = (_borderBottomStyle == WXBorderStyleDashed ? 3 : 1) * _borderBottomWidth;
            CGContextSetLineDash(context, 0, lengths, sizeof(lengths) / sizeof(*lengths));
        } else{
            CGContextSetLineDash(context, 0, 0, 0);
        }
        CGContextSetLineWidth(context, _borderBottomWidth);
        CGContextSetStrokeColorWithColor(context, _borderBottomColor.CGColor);
        CGContextAddArc(context, bottomLeft, size.height-bottomLeft, bottomLeft-_borderBottomWidth/2, M_PI-M_PI_4+(_borderLeftWidth>0?0:M_PI_4), M_PI_2, 1);
        CGContextMoveToPoint(context, bottomLeft, size.height-_borderBottomWidth/2);
        CGContextAddLineToPoint(context, size.width-bottomRight, size.height-_borderBottomWidth/2);
        CGContextAddArc(context, size.width-bottomRight, size.height-bottomRight, bottomRight-_borderBottomWidth/2, M_PI_2, M_PI_4-(_borderRightWidth > 0?0:M_PI_4), 1);
        CGContextStrokePath(context);
    }
    
    // Right
    if (_borderRightWidth > 0) {
        if(_borderRightStyle == WXBorderStyleDashed || _borderRightStyle == WXBorderStyleDotted){
            CGFloat lengths[2];
            lengths[0] = lengths[1] = (_borderRightStyle == WXBorderStyleDashed ? 3 : 1) * _borderRightWidth;
            CGContextSetLineDash(context, 0, lengths, sizeof(lengths) / sizeof(*lengths));
        } else{
            CGContextSetLineDash(context, 0, 0, 0);
        }
        CGContextSetLineWidth(context, _borderRightWidth);
        CGContextSetStrokeColorWithColor(context, _borderRightColor.CGColor);
        CGContextAddArc(context, size.width-bottomRight, size.height-bottomRight, bottomRight-_borderRightWidth/2, M_PI_4+(_borderBottomWidth>0?0:M_PI_4), 0, 1);
        CGContextMoveToPoint(context, size.width-_borderRightWidth/2, size.height-bottomRight);
        CGContextAddLineToPoint(context, size.width-_borderRightWidth/2, topRight);
        CGContextAddArc(context, size.width-topRight, topRight, topRight-_borderRightWidth/2, 0, -M_PI_4-(_borderTopWidth > 0?0:M_PI_4), 1);
        CGContextStrokePath(context);
    }
    
    CGContextStrokePath(context);
}

- (BOOL)_needsDrawBorder
{
    if (![_layer isKindOfClass:[WXLayer class]]) {
        // Only support WXLayer
        return NO;
    }
    // Set border property for most of components because border drawing consumes a lot of memory (v0.6.0)
//    if (_async) {
//        // Async layer always draw border
//        return YES;
//    }
    if (!(_borderLeftStyle == _borderTopStyle &&
          _borderTopStyle == _borderRightStyle &&
          _borderRightStyle == _borderBottomStyle &&
          _borderBottomStyle == WXBorderStyleSolid)
        ) {
        // Native border property doesn't support dashed or dotted border
        return YES;
    }
    
    // user native border property only when border width & color & radius are equal;
    BOOL widthEqual = _borderTopWidth == _borderRightWidth && _borderRightWidth == _borderBottomWidth && _borderBottomWidth == _borderLeftWidth;
    if (!widthEqual) {
        return YES;
    }
    BOOL radiusEqual = _borderTopLeftRadius == _borderTopRightRadius && _borderTopRightRadius == _borderBottomRightRadius && _borderBottomRightRadius == _borderBottomLeftRadius;
    if (!radiusEqual) {
        return YES;
    }
    BOOL colorEqual = [_borderTopColor isEqual:_borderRightColor] && [_borderRightColor isEqual:_borderBottomColor] && [_borderBottomColor isEqual:_borderLeftColor];
    if (!colorEqual) {
        return YES;
    }
    
    return NO;
}

- (void)_handleBorders:(NSDictionary *)styles isUpdating:(BOOL)updating
{
    if (!updating) {
        // init with default value
        _borderTopStyle = _borderRightStyle = _borderBottomStyle = _borderLeftStyle = WXBorderStyleSolid;
        _borderTopColor = _borderLeftColor = _borderRightColor = _borderBottomColor = [UIColor blackColor];
        _borderTopWidth = _borderLeftWidth = _borderRightWidth = _borderBottomWidth = 0;
        _borderTopLeftRadius = _borderTopRightRadius = _borderBottomLeftRadius = _borderBottomRightRadius = 0;
    }
    
    BOOL previousNeedsDrawBorder = YES;
    if (updating) {
        previousNeedsDrawBorder = [self _needsDrawBorder];
    }
    
#define WX_CHECK_BORDER_PROP(prop, direction1, direction2, direction3, direction4, type)\
do {\
    BOOL needsDisplay = NO; \
    NSString *styleProp= WX_NSSTRING(WX_CONCAT(border, prop));\
    if (styles[styleProp]) {\
        _border##direction1##prop = _border##direction2##prop = _border##direction3##prop = _border##direction4##prop = [WXConvert type:styles[styleProp]];\
        needsDisplay = YES;\
    }\
    NSString *styleDirection1Prop = WX_NSSTRING(WX_CONCAT_TRIPLE(border, direction1, prop));\
    if (styles[styleDirection1Prop]) {\
        _border##direction1##prop = [WXConvert type:styles[styleDirection1Prop]];\
        needsDisplay = YES;\
    }\
    NSString *styleDirection2Prop = WX_NSSTRING(WX_CONCAT_TRIPLE(border, direction2, prop));\
    if (styles[styleDirection2Prop]) {\
        _border##direction2##prop = [WXConvert type:styles[styleDirection2Prop]];\
        needsDisplay = YES;\
    }\
    NSString *styleDirection3Prop = WX_NSSTRING(WX_CONCAT_TRIPLE(border, direction3, prop));\
    if (styles[styleDirection3Prop]) {\
        _border##direction3##prop = [WXConvert type:styles[styleDirection3Prop]];\
        needsDisplay = YES;\
    }\
    NSString *styleDirection4Prop = WX_NSSTRING(WX_CONCAT_TRIPLE(border, direction4, prop));\
    if (styles[styleDirection4Prop]) {\
        _border##direction4##prop = [WXConvert type:styles[styleDirection4Prop]];\
        needsDisplay = YES;\
    }\
    if (needsDisplay && updating) {\
        [self setNeedsDisplay];\
    }\
} while (0);
    
// TODO: refactor this hopefully
#define WX_CHECK_BORDER_PROP_PIXEL(prop, direction1, direction2, direction3, direction4)\
do {\
    BOOL needsDisplay = NO; \
    NSString *styleProp= WX_NSSTRING(WX_CONCAT(border, prop));\
    if (styles[styleProp]) {\
        _border##direction1##prop = _border##direction2##prop = _border##direction3##prop = _border##direction4##prop = [WXConvert WXPixelType:styles[styleProp] scaleFactor:self.weexInstance.pixelScaleFactor];\
    needsDisplay = YES;\
    }\
    NSString *styleDirection1Prop = WX_NSSTRING(WX_CONCAT_TRIPLE(border, direction1, prop));\
    if (styles[styleDirection1Prop]) {\
        _border##direction1##prop = [WXConvert WXPixelType:styles[styleDirection1Prop] scaleFactor:self.weexInstance.pixelScaleFactor];\
        needsDisplay = YES;\
    }\
    NSString *styleDirection2Prop = WX_NSSTRING(WX_CONCAT_TRIPLE(border, direction2, prop));\
    if (styles[styleDirection2Prop]) {\
        _border##direction2##prop = [WXConvert WXPixelType:styles[styleDirection2Prop] scaleFactor:self.weexInstance.pixelScaleFactor];\
        needsDisplay = YES;\
    }\
    NSString *styleDirection3Prop = WX_NSSTRING(WX_CONCAT_TRIPLE(border, direction3, prop));\
    if (styles[styleDirection3Prop]) {\
        _border##direction3##prop = [WXConvert WXPixelType:styles[styleDirection3Prop] scaleFactor:self.weexInstance.pixelScaleFactor];\
        needsDisplay = YES;\
    }\
    NSString *styleDirection4Prop = WX_NSSTRING(WX_CONCAT_TRIPLE(border, direction4, prop));\
    if (styles[styleDirection4Prop]) {\
        _border##direction4##prop = [WXConvert WXPixelType:styles[styleDirection4Prop] scaleFactor:self.weexInstance.pixelScaleFactor];\
        needsDisplay = YES;\
    }\
    if (needsDisplay && updating) {\
        [self setNeedsDisplay];\
    }\
} while (0);
    
    
    WX_CHECK_BORDER_PROP(Style, Top, Left, Bottom, Right, WXBorderStyle)
    WX_CHECK_BORDER_PROP(Color, Top, Left, Bottom, Right, UIColor)
    WX_CHECK_BORDER_PROP_PIXEL(Width, Top, Left, Bottom, Right)
    WX_CHECK_BORDER_PROP_PIXEL(Radius, TopLeft, TopRight, BottomLeft, BottomRight)

    if (updating) {
        BOOL nowNeedsDrawBorder = [self _needsDrawBorder];
        if (nowNeedsDrawBorder && !previousNeedsDrawBorder) {
            _layer.cornerRadius = 0;
            _layer.borderWidth = 0;
            _layer.backgroundColor = NULL;
        } else if (!nowNeedsDrawBorder) {
            [self _resetNativeBorderRadius];
            _layer.borderWidth = _borderTopWidth;
            _layer.borderColor = _borderTopColor.CGColor;
            _layer.backgroundColor = _backgroundColor.CGColor;
        }
    }
}

@end
