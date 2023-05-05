#include <stdlib.h>
#include <unistd.h>
#include <stdio.h>
#include <sys/types.h>

#include <mach/mach.h>
#include <mach/mach_init.h>
#include <mach/mach_port.h>
#include <mach/message.h>
#include <mach/vm_map.h>

#include <Metal/Metal.h>
#include <MetalKit/MetalKit.h>
#include <QuartzCore/CALayer.h>

constexpr unsigned kWidth = 640;
constexpr unsigned kHeight = 480;

struct Vertex {
  float position[4];
  float color[4];
};

// Helper to send `port` over `remote_port`.
static int32_t send_port(mach_port_t remote_port, mach_port_t port) {
    kern_return_t err;

    struct {
        mach_msg_header_t          header;
        mach_msg_body_t            body;
        mach_msg_port_descriptor_t task_port;
    } msg;

    msg.header.msgh_remote_port = remote_port;
    msg.header.msgh_local_port = MACH_PORT_NULL;
    msg.header.msgh_bits = MACH_MSGH_BITS (MACH_MSG_TYPE_COPY_SEND, 0) |
        MACH_MSGH_BITS_COMPLEX;
    msg.header.msgh_size = sizeof msg;

    msg.body.msgh_descriptor_count = 1;
    msg.task_port.name = port;
    msg.task_port.disposition = MACH_MSG_TYPE_COPY_SEND;
    msg.task_port.type = MACH_MSG_PORT_DESCRIPTOR;

    err = mach_msg_send(&msg.header);
    if (err != KERN_SUCCESS) {
        mach_error("Can't send mach msg\n", err);
        exit(1);
    }

    return 0;
}

// Helper to receive `port` from `recv_port`.
static int32_t recv_port(mach_port_t recv_port, mach_port_t *port) {
    kern_return_t err;
    struct {
        mach_msg_header_t          header;
        mach_msg_body_t            body;
        mach_msg_port_descriptor_t task_port;
        mach_msg_trailer_t         trailer;
    } msg;

    err = mach_msg(&msg.header, MACH_RCV_MSG,
                    0, sizeof msg, recv_port,
                    MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
    if(err != KERN_SUCCESS)
    {
        mach_error("Can't recieve mach message\n", err);
        exit(1);
    }

    *port = msg.task_port.name;
    return 0;
}

// Helper to create a port to receive messages on.
static int32_t setup_recv_port(mach_port_t *recv_port) {
    kern_return_t       err;
    mach_port_t         port = MACH_PORT_NULL;
    err = mach_port_allocate(mach_task_self(),
                             MACH_PORT_RIGHT_RECEIVE, &port);
    if(err != KERN_SUCCESS) {
        mach_error("Can't allocate mach port\n", err);
        exit(1);
    }

    err = mach_port_insert_right(mach_task_self (),
                                  port,
                                  port,
                                  MACH_MSG_TYPE_MAKE_SEND);
    if(err != KERN_SUCCESS) {
        mach_error("Can't insert port right\n", err);
        exit(1);
    }

    (*recv_port) = port;
    return 0;
}

size_t align(size_t size, size_t alignment) {
  return ((size + alignment - 1) / alignment) * alignment;
}

int main(int argc, char* argv[]) {
  unsigned long long num_triangles = 1'000'000;

  if (argc > 1) {
    num_triangles = atoi(argv[1]);
  }
  unsigned long long buffer_size = 3 * sizeof(Vertex) * num_triangles;

  bool use_copy = argc > 2 && strcmp(argv[2], "copy") == 0;
  printf("num_triangles: %llu\tcopy: %d\n", num_triangles, use_copy);

  // Metal requires the buffer size wrapping a VM allocation to be aligned to 4096.
  unsigned long long vm_size = align(buffer_size, 4096);

  kern_return_t err;
  /* Setup a mach port. The child will send the memory port to the parent with it. */
  mach_port_t parent_port;
  if(setup_recv_port(&parent_port) != 0) {
      fprintf(stderr, "Can't setup mach port\n");
      exit(1);
  }

  /* Grab our current process's bootstrap port. */
  mach_port_t bootstrap_port = MACH_PORT_NULL;
  err = task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, &bootstrap_port);
  if(err != KERN_SUCCESS)
  {
      mach_error("Can't get special port:\n", err);
      exit(1);
  }

  /* Set the port as the bootstrap port so the child process can get it. */
  err = task_set_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, parent_port);
  if(err != KERN_SUCCESS)
  {
      mach_error("Can't set special port:\n", err);
      exit(1);
  }

  pid_t child_pid = fork();
  if (child_pid < 0) {
    fprintf(stderr, "failed to fork\n");
    exit(1);
  } else if (child_pid == 0) {
    mach_port_t bootstrap_port = MACH_PORT_NULL;
    mach_port_t port = MACH_PORT_NULL;

    /* In the child process grab the port passed by the parent. */
    err = task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, &parent_port);
    if (err != KERN_SUCCESS) {
        mach_error("Can't get special port:\n", err);
        exit(1);
    }

    // Create a VM allocation with a memory port.
    mach_port_t mem_port;
    if (mach_make_memory_entry_64(
          mach_task_self(), &vm_size, 0,
          MAP_MEM_NAMED_CREATE | VM_PROT_READ | VM_PROT_WRITE,
          &mem_port, /* parent_entry */ MACH_PORT_NULL) != KERN_SUCCESS) {
      fprintf(stderr, "failed to allocate\n");
      exit(1);
    }

    /* Send memory port to parent. */
    if(send_port(parent_port, mem_port) < 0)
    {
        fprintf(stderr, "Can't send port\n");
        exit(1);
    }

    // Map the memory port in the child procress.
    vm_address_t vm_address = 0;
    if (vm_map(mach_task_self(),
              &vm_address,
              vm_size,
              0,  // Alignment mask
              VM_FLAGS_ANYWHERE, mem_port,   /* offset */ 0,
              false,                         // Copy
              VM_PROT_READ | VM_PROT_WRITE,  // Current protection
              VM_PROT_READ | VM_PROT_WRITE,  // Maximum protection
              VM_INHERIT_NONE) != KERN_SUCCESS) {
      fprintf(stderr, "child failed to map\n");
      exit(1);
    }

    using Triangle = Vertex[3];
    Triangle* triangles = reinterpret_cast<Triangle*>(vm_address);

    // Initialize triangle positions
    for (uint32_t t = 0; t < num_triangles; ++t) {
      float x = (static_cast<float>(rand()) / RAND_MAX) * 2.0 - 1.0;
      float y = (static_cast<float>(rand()) / RAND_MAX) * 2.0 - 1.0;

      triangles[t][0] = {{x + 0.01f, y + 0.01f, 0.0, 1.0}};
      triangles[t][1] = {{x - 0.01f, y + 0.01f, 0.0, 1.0}};
      triangles[t][2] = {{x + 0.0f,  y - 0.01f, 0.0, 1.0}};
    }

    // Continually update triangle colors.
    for (uint32_t i = 0; ;) {
      for (uint32_t t = 0; t < num_triangles; ++t, ++i) {
        triangles[t][0].color[0] = 0.5 * cos(static_cast<float>(i) / 100.0) + 0.5;
        triangles[t][1].color[1] = 0.5 * cos(static_cast<float>(i + 100) / 100.0) + 0.5;
        triangles[t][2].color[2] = 0.5 * cos(static_cast<float>(i + 200) / 100.0) + 0.5;
      }
    }
  } else {
    // Parent process receives the memory port from the child.
    mach_port_t mem_port = MACH_PORT_NULL;
    if(recv_port(parent_port, &mem_port) < 0) {
        fprintf(stderr, "Can't recv port\n");
        exit(1);
    }

    /* Reset parents special port. */
    err = task_set_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, bootstrap_port);
    if (err != KERN_SUCCESS) {
        mach_error("Can't set special port:\n", err);
        exit(1);
    }

    // Map the memory port.
    vm_address_t vm_address = 0;
    if (vm_map(mach_task_self(),
              &vm_address,
              vm_size,
              0,  // Alignment mask
              VM_FLAGS_ANYWHERE, mem_port, /* offset */ 0,
              false,                         // Copy
              VM_PROT_READ | VM_PROT_WRITE,  // Current protection
              VM_PROT_READ | VM_PROT_WRITE,  // Maximum protection
              VM_INHERIT_NONE) != KERN_SUCCESS) {
      fprintf(stderr, "parent failed to map\n");
      exit(1);
    }

    // Get the Metal device and queue.
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> queue = [device newCommandQueue];

    id<MTLBuffer> buffer;
    if (use_copy) {
      // Create a normal buffer shared between the CPU and GPU.
      buffer = [device newBufferWithLength:buffer_size
                                   options:MTLResourceCPUCacheModeWriteCombined | MTLResourceStorageModeShared];
    } else {
      // Create a buffer wrapping the vm allocation.
      buffer = [device newBufferWithBytesNoCopy:reinterpret_cast<void*>(vm_address)
                                         length:vm_size
                                        options:MTLResourceCPUCacheModeWriteCombined | MTLResourceStorageModeShared
                                    deallocator:^(void *pointer, NSUInteger length) {}];
    }

    MTLCompileOptions* compileOptions = [[MTLCompileOptions alloc] init];
    NSError* error = nullptr;
    id<MTLLibrary> library = [device newLibraryWithSource:[[NSString alloc] initWithUTF8String:R"(
using namespace metal;


struct VertexIn {
    float4 position [[attribute(0)]];
    float4 color    [[attribute(1)]];
};

struct VertexOut
{
    float4 position [[position]];
    float4 color;
};

vertex VertexOut vertex_main(VertexIn in [[stage_in]], uint vid [[vertex_id]])
{
    VertexOut out;
    out.position = in.position;
    out.color = in.color;
    return out;
}

fragment float4 fragment_main(VertexOut vert [[stage_in]])
{
    return vert.color;
}
    )"]
                                                  options:compileOptions
                                                    error:&error];


    if (error != nil) {
        fprintf(stderr, "%s", [error.localizedDescription UTF8String]);
        exit(1);
    }

    id<MTLFunction> vertexFunc = [library newFunctionWithName:@"vertex_main"];
    id<MTLFunction> fragmentFunc = [library newFunctionWithName:@"fragment_main"];

    MTLRenderPipelineDescriptor* pipelineDescriptor = [MTLRenderPipelineDescriptor new];
    pipelineDescriptor.vertexFunction = vertexFunc;
    pipelineDescriptor.fragmentFunction = fragmentFunc;
    pipelineDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

    MTLVertexDescriptor* vertexDesc = [MTLVertexDescriptor new];

    auto positionAttrib = [MTLVertexAttributeDescriptor new];
    positionAttrib.format = MTLVertexFormatFloat4;
    positionAttrib.offset = offsetof(Vertex, position);
    positionAttrib.bufferIndex = 0;
    vertexDesc.attributes[0] = positionAttrib;

    auto colorAttrib = [MTLVertexAttributeDescriptor new];
    colorAttrib.format = MTLVertexFormatFloat4;
    colorAttrib.offset = offsetof(Vertex, color);
    colorAttrib.bufferIndex = 0;
    vertexDesc.attributes[1] = colorAttrib;

    MTLVertexBufferLayoutDescriptor* layoutDesc = [MTLVertexBufferLayoutDescriptor new];
    layoutDesc.stepFunction =  MTLVertexStepFunctionPerVertex;
    layoutDesc.stepRate = 1;
    layoutDesc.stride = sizeof(Vertex);

    vertexDesc.layouts[0] = layoutDesc;
    pipelineDescriptor.vertexDescriptor = vertexDesc;

    id<MTLRenderPipelineState> pipelineState =
      [device newRenderPipelineStateWithDescriptor:pipelineDescriptor
                                             error:&error];
    if (error != nil) {
        fprintf(stderr, "%s", [error.localizedDescription UTF8String]);
        exit(1);
    }

    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

    NSMenu* menubar = [NSMenu alloc];
    [NSApp setMainMenu:menubar];

    NSWindow* window = [[NSWindow alloc]
      initWithContentRect:NSMakeRect(0, 0, kWidth, kHeight)
      styleMask:NSWindowStyleMaskResizable | NSWindowStyleMaskTitled
      backing:NSBackingStoreBuffered
      defer:NO];
    [window setOpaque:YES];

    CALayer* layer = [[CALayer alloc] init];
    [[window contentView] setLayer:layer];
    [[window contentView] setWantsLayer:YES];

    CAMetalLayer* metal_layer = [[CAMetalLayer alloc] init];
    [metal_layer setDevice:device];
    [metal_layer setFramebufferOnly:true];
    [metal_layer setPixelFormat:MTLPixelFormatBGRA8Unorm];

    [layer addSublayer:metal_layer];
    [metal_layer setFrame:CGRectMake(0, 0, kWidth, kHeight)];

    [window setTitle:@"Test"];
    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    __block CFTimeInterval average = 0;

    for (uint32_t frame = 0;; ++frame) {
      while (true) {
        NSEvent* event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                            untilDate:[NSDate distantPast]
                                               inMode:NSDefaultRunLoopMode
                                              dequeue:YES];
        if (event == nil)
            break;

        [NSApp sendEvent:event];
      }

      id<CAMetalDrawable> drawable = [metal_layer nextDrawable];
      id<MTLTexture> backbuffer = [drawable texture];

      CFTimeInterval start = CACurrentMediaTime();

      if (use_copy) {
        // Copy data from the child process to the buffer.
        using Triangle = Vertex[3];
        Triangle* triangles = reinterpret_cast<Triangle*>(vm_address);
        memcpy([buffer contents], triangles, sizeof(Triangle) * num_triangles);
      }

      id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
      {
        MTLRenderPassDescriptor* renderPassDesc = [MTLRenderPassDescriptor renderPassDescriptor];
        renderPassDesc.colorAttachments[0].texture = backbuffer;
        renderPassDesc.colorAttachments[0].loadAction = MTLLoadActionClear;
        renderPassDesc.colorAttachments[0].storeAction = MTLStoreActionStore;
        renderPassDesc.colorAttachments[0].clearColor = MTLClearColorMake(0.2, 0.2, 0.2, 1.0);
        id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDesc];
        [encoder setRenderPipelineState:pipelineState];
        [encoder setVertexBuffer:buffer offset:0 atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                    vertexStart:0
                    vertexCount:3u * num_triangles
                  instanceCount:1];
        [encoder endEncoding];
      }

      [commandBuffer presentDrawable:drawable];
      [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> c) {
        CFTimeInterval end = [c GPUEndTime];

        average = (average * frame + (end - start)) / (frame + 1);
        if (frame % 1000 == 0) {
          printf("%f µs\n", average * 1'000'000);
        }
      }];
      [commandBuffer commit];
    }
  }
  return 0;
}
