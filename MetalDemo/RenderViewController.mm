//
//  RenderViewController.mm
//  MetalDemo
//
//  Created by Roman Kuznetsov on 23.01.15.
//  Copyright (c) 2015 rokuz. All rights reserved.
//

#import "RenderViewController.h"
#import "math/Math.h"
#import "camera/ArcballCamera.h"
#import "geometry/Primitives.h"
#import "geometry/Mesh.h"
#import "texture/Texture.h"
#import "renderer/SkyboxRenderer.h"

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

static const int MAX_INFLIGHT_BUFFERS = 3;
static const int INSTANCES_IN_ROW = 3;
static const int INSTANCES_COUNT = INSTANCES_IN_ROW * INSTANCES_IN_ROW;

typedef struct
{
    matrix_float4x4 viewProjection;
    simd::float3 viewPosition;
} Uniforms_T;

typedef struct
{
    matrix_float4x4 model;
} InstanceUniforms_T;

@implementation RenderViewController
{
    // infrastructure
    CADisplayLink* _timer;
    BOOL _renderLoopPaused;
    dispatch_semaphore_t _inflightSemaphore;
    BOOL _firstFrameRendered;
    CFTimeInterval _lastTime;
    CFTimeInterval _frameTime;
    ArcballCamera camera;
    
    // renderer
    id <MTLCommandQueue> _commandQueue;
    id <MTLLibrary> _defaultLibrary;
    id <MTLRenderPipelineState> _pipelineState;
    id <MTLDepthStencilState> _depthState;
    
    SkyboxRenderer *_skyboxRenderer;
    
    Texture *_defDiffuseTexture;
    Texture *_defNormalTexture;
    
    Mesh *_mesh;
    Texture *_diffuseTexture;
    Texture *_normalTexture;
    Texture *_skyboxTexture;
    id <MTLBuffer> _dynamicUniformBuffer;
    id <MTLBuffer> _staticInstancesUniformBuffer;
    uint8_t _currentUniformBufferIndex;
    
    dispatch_semaphore_t _renderThreadSemaphore;
    
    // uniforms
    matrix_float4x4 _projectionMatrix;
    matrix_float4x4 _viewMatrix;
    Uniforms_T _uniformBuffer;
    InstanceUniforms_T _instancesUniformBuffer[INSTANCES_COUNT];
}

#pragma mark - Infrastructure

- (void)dealloc
{
    [self cleanup];
    [self stopTimer];
    _timer = 0;
}

- (void)initCommon
{
    _firstFrameRendered = NO;
    _lastTime = 0;
    _frameTime = 0;
}

- (id)init
{
    self = [super init];
    if(self)
    {
        [self initCommon];
    }
    return self;
}

- (id)initWithNibName:(NSString *)nibNameOrNil
               bundle:(NSBundle *)nibBundleOrNil
{
    self = [super initWithNibName:nibNameOrNil
                           bundle:nibBundleOrNil];
    if(self)
    {
        [self initCommon];
    }
    return self;
}

- (id)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if(self)
    {
        [self initCommon];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    ((RenderView*)self.view).delegate = self;
    [self configure: (RenderView*)self.view];
    
    _currentUniformBufferIndex = 0;
    _inflightSemaphore = dispatch_semaphore_create(MAX_INFLIGHT_BUFFERS);
    
    [self setupMetal: ((RenderView*)self.view).device];
    [self startTimer];
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
}

- (BOOL)prefersStatusBarHidden
{
    return YES;
}

- (void)didEnterBackground
{
    NSLog(@"Rendering stopped");
    _renderLoopPaused = YES;
    _timer.paused = YES;
    [(RenderView*)self.view processBackgroundEntering];
}

- (void)willEnterForeground
{
     NSLog(@"Rendering started");
    _renderLoopPaused = NO;
    _timer.paused = NO;
    
    _firstFrameRendered = NO;
    _lastTime = 0;
    _frameTime = 0;
}

- (BOOL)isPaused
{
    return _renderLoopPaused;
}

- (void)startTimer
{
    _timer = [CADisplayLink displayLinkWithTarget:self selector:@selector(_renderloop)];
    [_timer addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
}

- (void)stopTimer
{
    [_timer invalidate];
}

- (void)_renderloop
{
    if(!_firstFrameRendered)
    {
        _frameTime = 0;
        _lastTime = CACurrentMediaTime();
        _firstFrameRendered = YES;
    }
    else
    {
        CFTimeInterval currentTime = CACurrentMediaTime();
        _frameTime = currentTime - _lastTime;
        _lastTime = currentTime;
    }
    
    [(RenderView*)self.view render];
}

#pragma mark - Renderer

- (void)configure:(RenderView*)renderView
{
    renderView.sampleCount = 1;
    camera.init(-50.0f, -20.0f, 70.0f);
}

- (void)setupMetal:(id<MTLDevice>)device
{
    _renderThreadSemaphore = dispatch_semaphore_create(0);
    
    _commandQueue = [device newCommandQueue];
    _defaultLibrary = [device newDefaultLibrary];
    
    [self loadAssets: device];
}

- (void)cleanup
{
    _mesh = nil;
    _commandQueue = nil;
    _defaultLibrary = nil;
    _pipelineState = nil;
    _depthState = nil;
    _dynamicUniformBuffer = nil;
    _staticInstancesUniformBuffer = nil;
    _diffuseTexture = nil;
    _normalTexture = nil;
    _skyboxTexture = nil;
    _defDiffuseTexture = nil;
    _defNormalTexture = nil;
    _skyboxRenderer = nil;
}

- (void)loadAssets:(id<MTLDevice>)device
{
    // default textures
    _defDiffuseTexture = [[Texture alloc] initWithResourceName:@"default_diff" Extension:@"png"];
    [_defDiffuseTexture loadWithDevice:device Asynchronously:NO];
    _defNormalTexture = [[Texture alloc] initWithResourceName:@"default_normal" Extension:@"png"];
    [_defNormalTexture loadWithDevice:device Asynchronously:NO];
    
    // skybox
    _skyboxRenderer = [[SkyboxRenderer alloc] init];
    [_skyboxRenderer setupWithView:(RenderView*)self.view
                           Library:_defaultLibrary InflightBuffersCount:MAX_INFLIGHT_BUFFERS];

    // mesh
    _mesh = [[Mesh alloc] initWithResourceName:@"spaceship"];
    [_mesh loadWithDevice:device Asynchronously:YES];
    
    // uniform buffers
    NSUInteger sz = sizeof(_uniformBuffer) * MAX_INFLIGHT_BUFFERS;
    _dynamicUniformBuffer = [device newBufferWithLength:sz options:0];
    _dynamicUniformBuffer.label = @"Uniform buffer";
    
    sz = sizeof(_instancesUniformBuffer);
    matrix_float4x4 rotMatrix = Math::rotate(-90, 1, 0, 0);
    int cnt = INSTANCES_IN_ROW / 2 + (INSTANCES_IN_ROW % 2 != 0 ? 1 : 0);
    int instance = 0;
    for (int i = -INSTANCES_IN_ROW / 2; i < cnt; i++)
    {
        for (int j = -INSTANCES_IN_ROW / 2; j < cnt; j++)
        {
            matrix_float4x4 transMatrix = Math::translate(i * 35.0f, 0, j * 35.0f);
            _instancesUniformBuffer[instance++].model = matrix_multiply(transMatrix, rotMatrix);
        }
    }
    _staticInstancesUniformBuffer= [device newBufferWithBytes:_instancesUniformBuffer
                                                       length:sz
                                                      options:MTLResourceOptionCPUCacheModeDefault];
    _staticInstancesUniformBuffer.label = @"Instances uniform buffer";
    
    // shaders
    id <MTLFunction> fragmentProgram = [_defaultLibrary newFunctionWithName:@"psLighting"];
    id <MTLFunction> vertexProgram = [_defaultLibrary newFunctionWithName:@"vsLighting"];
    
    // textures
    _diffuseTexture = [[Texture alloc] initWithResourceName:@"spaceship_diff" Extension:@"png"];
    [_diffuseTexture loadWithDevice:device Asynchronously:YES];
    _normalTexture = [[Texture alloc] initWithResourceName:@"spaceship_normal" Extension:@"png"];
    [_normalTexture loadWithDevice:device Asynchronously:YES];
    NSArray *skybox = [NSArray arrayWithObjects:@"nightsky_right", @"nightsky_left",
                                                @"nightsky_top", @"nightsky_bottom",
                                                @"nightsky_front", @"nightsky_back", nil];
    _skyboxTexture = [[Texture alloc] initCubeWithResourceNames:skybox Extension:@"jpg"];
    [_skyboxTexture loadWithDevice:device Asynchronously:YES];
    
    // pipeline state
    MTLRenderPipelineDescriptor *pipelineStateDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
    pipelineStateDescriptor.label = @"Simple pipeline";
    [pipelineStateDescriptor setSampleCount: ((RenderView*)self.view).sampleCount];
    [pipelineStateDescriptor setVertexFunction:vertexProgram];
    [pipelineStateDescriptor setFragmentFunction:fragmentProgram];
    pipelineStateDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    pipelineStateDescriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    
    NSError* error = NULL;
    _pipelineState = [device newRenderPipelineStateWithDescriptor:pipelineStateDescriptor error:&error];
    if (!_pipelineState)
    {
        NSLog(@"Failed to created pipeline state, error %@", error);
    }
    
    MTLDepthStencilDescriptor *depthStateDesc = [[MTLDepthStencilDescriptor alloc] init];
    depthStateDesc.depthCompareFunction = MTLCompareFunctionLess;
    depthStateDesc.depthWriteEnabled = YES;
    _depthState = [device newDepthStencilStateWithDescriptor:depthStateDesc];
}

- (void)render:(RenderView*)renderView
{
    dispatch_semaphore_wait(_inflightSemaphore, DISPATCH_TIME_FOREVER);
    
    [self update];
    
    MTLRenderPassDescriptor* renderPassDescriptor = renderView.renderPassDescriptor;
    id <CAMetalDrawable> drawable = renderView.currentDrawable;
    
    // new command buffer
    id <MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    commandBuffer.label = @"Command buffer";
    
    // generate mipmaps
    [_diffuseTexture generateMipMapsIfNecessary:commandBuffer];
    [_normalTexture generateMipMapsIfNecessary:commandBuffer];
    
    // parallel render encoder
    id <MTLParallelRenderCommandEncoder> parallelRCE = [commandBuffer parallelRenderCommandEncoderWithDescriptor:renderPassDescriptor];
    parallelRCE.label = @"Parallel render encoder";
    id <MTLRenderCommandEncoder> skyboxEncoder = [parallelRCE renderCommandEncoder];
    id <MTLRenderCommandEncoder> renderEncoder = [parallelRCE renderCommandEncoder];
    
    // skybox
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^
    {
        @autoreleasepool
        {
            if (_skyboxTexture.isReady)
            {
                [_skyboxRenderer renderWithEncoder:skyboxEncoder
                                           Texture:_skyboxTexture
                                     IndexOfBuffer:_currentUniformBufferIndex];
            }
            [skyboxEncoder endEncoding];
        }
        dispatch_semaphore_signal(_renderThreadSemaphore);
    });

    // scene
    if (_mesh.isReady)
    {
        [renderEncoder setDepthStencilState:_depthState];
        [renderEncoder pushDebugGroup:@"Draw mesh"];
        [renderEncoder setRenderPipelineState:_pipelineState];
        [renderEncoder setVertexBuffer:_mesh.vertexBuffer offset:0 atIndex:0];
        [renderEncoder setVertexBuffer:_dynamicUniformBuffer
                                offset:(sizeof(_uniformBuffer) * _currentUniformBufferIndex)
                               atIndex:1];
        [renderEncoder setVertexBuffer:_staticInstancesUniformBuffer offset:0 atIndex:2];
        [renderEncoder setFragmentTexture:(_diffuseTexture.isReady ? _diffuseTexture.texture : _defDiffuseTexture.texture)
                                  atIndex:0];
        [renderEncoder setFragmentTexture:(_normalTexture.isReady ? _normalTexture.texture : _defNormalTexture.texture)
                                  atIndex:1];
        [_mesh drawAllInstanced:INSTANCES_COUNT WithEncoder:renderEncoder];
        [renderEncoder popDebugGroup];
    }
    [renderEncoder endEncoding];
    
    // wait all threads and finish encoding
    dispatch_semaphore_wait(_renderThreadSemaphore, DISPATCH_TIME_FOREVER);
    [parallelRCE endEncoding];

    dispatch_semaphore_t block_sema = _inflightSemaphore;
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
        dispatch_semaphore_signal(block_sema);
    }];
    
    _currentUniformBufferIndex = (_currentUniformBufferIndex + 1) % MAX_INFLIGHT_BUFFERS;
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
}

- (void)resize:(RenderView*)renderView
{
    float aspect = fabsf(renderView.bounds.size.width / renderView.bounds.size.height);
    _projectionMatrix = Math::perspectiveFov(65.0f, aspect, 0.1f, 1000.0f);
    
    camera.updateView();
    _viewMatrix = camera.getView();
}

- (void)update
{
    camera.updateView();
    
    [_skyboxRenderer updateWithCamera:camera
                           Projection:_projectionMatrix
                        IndexOfBuffer:_currentUniformBufferIndex];
    
    _viewMatrix = camera.getView();
    _uniformBuffer.viewProjection = matrix_multiply(_projectionMatrix, _viewMatrix);
    _uniformBuffer.viewPosition = camera.getCurrentViewPosition();
    
    uint8_t* bufferPointer = (uint8_t*)[_dynamicUniformBuffer contents] + (sizeof(_uniformBuffer) * _currentUniformBufferIndex);
    memcpy(bufferPointer, &_uniformBuffer, sizeof(_uniformBuffer));
}

#pragma mark - Input handling

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event
{
    NSArray* touchesArray = [touches allObjects];
    if (touches.count == 1)
    {
        if (!camera.isRotatingNow())
        {
            CGPoint pos = [touchesArray[0] locationInView: self.view];
            camera.startRotation(pos.x, pos.y);
        }
        else
        {
            // here we put second finger
            simd::float2 lastPos = camera.getLastFingerPosition();
            camera.stopRotation();
            CGPoint pos = [touchesArray[0] locationInView: self.view];
            float d = vector_distance(simd::float2 { (float)pos.x, (float)pos.y }, lastPos);
            camera.startZooming(d);
        }
    }
    else if (touches.count == 2)
    {
        CGPoint pos1 = [touchesArray[0] locationInView: self.view];
        CGPoint pos2 = [touchesArray[1] locationInView: self.view];
        float d = vector_distance(simd::float2 { (float)pos1.x, (float)pos1.y },
                                  simd::float2 { (float)pos2.x, (float)pos2.y });
        camera.startZooming(d);
    }
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event
{
    NSArray* touchesArray = [touches allObjects];
    if (touches.count != 0 && camera.isRotatingNow())
    {
        CGPoint pos = [touchesArray[0] locationInView: self.view];
        camera.updateRotation(pos.x, pos.y);
    }
    else if (touches.count == 2 && camera.isZoomingNow())
    {
        CGPoint pos1 = [touchesArray[0] locationInView: self.view];
        CGPoint pos2 = [touchesArray[1] locationInView: self.view];
        float d = vector_distance(simd::float2 { (float)pos1.x, (float)pos1.y },
                                  simd::float2 { (float)pos2.x, (float)pos2.y });
        camera.updateZooming(d);
    }
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event
{
    camera.stopRotation();
    camera.stopZooming();
}

@end
