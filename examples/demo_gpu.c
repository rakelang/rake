/**
 * Rake Vulkan Compute Demo
 *
 * Compares ray-sphere intersection performance across:
 * - C Scalar (CPU)
 * - C SIMD AVX2 (CPU)
 * - Rake SIMD (CPU)
 * - Vulkan Compute (GPU)
 *
 * Build:
 *   glslc vulkan_raytracer.comp -o raytracer.spv
 *   clang -O3 -mavx2 vulkan_demo.c raytracer_rake.o -o vulkan_demo \
 *         -lvulkan -lm -lSDL2
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <stdbool.h>
#include <immintrin.h>

#include <vulkan/vulkan.h>
#include <SDL2/SDL.h>
#include <SDL2/SDL_vulkan.h>

/* Configuration */
#define WIDTH  800
#define HEIGHT 600
#define NUM_RAYS (WIDTH * HEIGHT)
#define NUM_SPHERES 5

/* Ray pack (SoA layout) */
typedef struct {
    float *ox, *oy, *oz;
    float *dx, *dy, *dz;
} RayPack;

typedef struct {
    float cx, cy, cz, r;
} Sphere;

/* External Rake functions */
extern __m256 intersect_flat(__m256 ray_ox, __m256 ray_oy, __m256 ray_oz,
                             __m256 ray_dx, __m256 ray_dy, __m256 ray_dz,
                             float sphere_cx, float sphere_cy, float sphere_cz,
                             float sphere_r);

/* Vulkan state */
typedef struct {
    VkInstance instance;
    VkPhysicalDevice physical_device;
    VkDevice device;
    VkQueue compute_queue;
    uint32_t queue_family;

    VkCommandPool command_pool;
    VkCommandBuffer command_buffer;

    VkDescriptorSetLayout descriptor_layout;
    VkDescriptorPool descriptor_pool;
    VkDescriptorSet descriptor_set;

    VkPipelineLayout pipeline_layout;
    VkPipeline pipeline;

    VkBuffer ray_buffers[6];  /* ox, oy, oz, dx, dy, dz */
    VkBuffer sphere_buffer;
    VkBuffer result_buffer;
    VkDeviceMemory memory;

    size_t buffer_size;
    bool initialized;
} VulkanState;

/* C Scalar implementation */
static inline float dot_scalar(float ax, float ay, float az,
                               float bx, float by, float bz) {
    return ax * bx + ay * by + az * bz;
}

float intersect_scalar(float ox, float oy, float oz,
                       float dx, float dy, float dz,
                       float cx, float cy, float cz, float r) {
    float ocx = ox - cx, ocy = oy - cy, ocz = oz - cz;
    float a = dot_scalar(dx, dy, dz, dx, dy, dz);
    float b = 2.0f * dot_scalar(ocx, ocy, ocz, dx, dy, dz);
    float c = dot_scalar(ocx, ocy, ocz, ocx, ocy, ocz) - r * r;
    float disc = b * b - 4.0f * a * c;
    if (disc < 0.0f) return -1.0f;
    float t = (-b - sqrtf(disc)) / (2.0f * a);
    return t > 0.0f ? t : -1.0f;
}

void trace_scalar(RayPack *rays, Sphere *spheres, int num_spheres, float *result) {
    for (int i = 0; i < NUM_RAYS; i++) {
        float closest = 1e30f;
        for (int s = 0; s < num_spheres; s++) {
            float t = intersect_scalar(rays->ox[i], rays->oy[i], rays->oz[i],
                                       rays->dx[i], rays->dy[i], rays->dz[i],
                                       spheres[s].cx, spheres[s].cy,
                                       spheres[s].cz, spheres[s].r);
            if (t > 0.0f && t < closest) closest = t;
        }
        result[i] = closest < 1e29f ? closest : -1.0f;
    }
}

/* C SIMD implementation */
static inline __m256 dot_simd(__m256 ax, __m256 ay, __m256 az,
                              __m256 bx, __m256 by, __m256 bz) {
    return _mm256_add_ps(_mm256_add_ps(_mm256_mul_ps(ax, bx),
                                        _mm256_mul_ps(ay, by)),
                         _mm256_mul_ps(az, bz));
}

__m256 intersect_simd(__m256 ox, __m256 oy, __m256 oz,
                      __m256 dx, __m256 dy, __m256 dz,
                      float cx, float cy, float cz, float r) {
    __m256 ocx = _mm256_sub_ps(ox, _mm256_set1_ps(cx));
    __m256 ocy = _mm256_sub_ps(oy, _mm256_set1_ps(cy));
    __m256 ocz = _mm256_sub_ps(oz, _mm256_set1_ps(cz));

    __m256 a = dot_simd(dx, dy, dz, dx, dy, dz);
    __m256 b = _mm256_mul_ps(_mm256_set1_ps(2.0f), dot_simd(ocx, ocy, ocz, dx, dy, dz));
    __m256 c = _mm256_sub_ps(dot_simd(ocx, ocy, ocz, ocx, ocy, ocz),
                             _mm256_set1_ps(r * r));

    __m256 disc = _mm256_sub_ps(_mm256_mul_ps(b, b),
                                 _mm256_mul_ps(_mm256_set1_ps(4.0f),
                                               _mm256_mul_ps(a, c)));

    __m256 miss = _mm256_cmp_ps(disc, _mm256_setzero_ps(), _CMP_LT_OQ);
    __m256 sqrt_disc = _mm256_sqrt_ps(disc);
    __m256 t = _mm256_div_ps(_mm256_sub_ps(_mm256_sub_ps(_mm256_setzero_ps(), b),
                                           sqrt_disc),
                             _mm256_mul_ps(_mm256_set1_ps(2.0f), a));

    return _mm256_blendv_ps(t, _mm256_set1_ps(-1.0f), miss);
}

void trace_simd(RayPack *rays, Sphere *spheres, int num_spheres, float *result) {
    for (int i = 0; i < NUM_RAYS; i++) result[i] = 1e30f;

    for (int s = 0; s < num_spheres; s++) {
        for (int i = 0; i < NUM_RAYS; i += 8) {
            __m256 ox = _mm256_loadu_ps(&rays->ox[i]);
            __m256 oy = _mm256_loadu_ps(&rays->oy[i]);
            __m256 oz = _mm256_loadu_ps(&rays->oz[i]);
            __m256 dx = _mm256_loadu_ps(&rays->dx[i]);
            __m256 dy = _mm256_loadu_ps(&rays->dy[i]);
            __m256 dz = _mm256_loadu_ps(&rays->dz[i]);

            __m256 t = intersect_simd(ox, oy, oz, dx, dy, dz,
                                      spheres[s].cx, spheres[s].cy,
                                      spheres[s].cz, spheres[s].r);

            __m256 current = _mm256_loadu_ps(&result[i]);
            __m256 closer = _mm256_and_ps(_mm256_cmp_ps(t, _mm256_setzero_ps(), _CMP_GT_OQ),
                                          _mm256_cmp_ps(t, current, _CMP_LT_OQ));
            _mm256_storeu_ps(&result[i], _mm256_blendv_ps(current, t, closer));
        }
    }

    for (int i = 0; i < NUM_RAYS; i++) {
        if (result[i] > 1e29f) result[i] = -1.0f;
    }
}

/* Rake SIMD wrapper */
void trace_rake(RayPack *rays, Sphere *spheres, int num_spheres, float *result) {
    for (int i = 0; i < NUM_RAYS; i++) result[i] = 1e30f;

    for (int s = 0; s < num_spheres; s++) {
        for (int i = 0; i < NUM_RAYS; i += 8) {
            __m256 ox = _mm256_loadu_ps(&rays->ox[i]);
            __m256 oy = _mm256_loadu_ps(&rays->oy[i]);
            __m256 oz = _mm256_loadu_ps(&rays->oz[i]);
            __m256 dx = _mm256_loadu_ps(&rays->dx[i]);
            __m256 dy = _mm256_loadu_ps(&rays->dy[i]);
            __m256 dz = _mm256_loadu_ps(&rays->dz[i]);

            __m256 t = intersect_flat(ox, oy, oz, dx, dy, dz,
                                      spheres[s].cx, spheres[s].cy,
                                      spheres[s].cz, spheres[s].r);

            __m256 current = _mm256_loadu_ps(&result[i]);
            __m256 closer = _mm256_and_ps(_mm256_cmp_ps(t, _mm256_setzero_ps(), _CMP_GT_OQ),
                                          _mm256_cmp_ps(t, current, _CMP_LT_OQ));
            _mm256_storeu_ps(&result[i], _mm256_blendv_ps(current, t, closer));
        }
    }

    for (int i = 0; i < NUM_RAYS; i++) {
        if (result[i] > 1e29f) result[i] = -1.0f;
    }
}

/* Vulkan initialization */
static uint32_t find_memory_type(VkPhysicalDevice pdev, uint32_t filter, VkMemoryPropertyFlags props) {
    VkPhysicalDeviceMemoryProperties mem_props;
    vkGetPhysicalDeviceMemoryProperties(pdev, &mem_props);

    for (uint32_t i = 0; i < mem_props.memoryTypeCount; i++) {
        if ((filter & (1 << i)) && (mem_props.memoryTypes[i].propertyFlags & props) == props) {
            return i;
        }
    }
    return UINT32_MAX;
}

static VkShaderModule load_shader(VkDevice device, const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "Failed to open shader: %s\n", path);
        return VK_NULL_HANDLE;
    }

    fseek(f, 0, SEEK_END);
    size_t size = ftell(f);
    fseek(f, 0, SEEK_SET);

    uint32_t *code = malloc(size);
    fread(code, 1, size, f);
    fclose(f);

    VkShaderModuleCreateInfo ci = {
        .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = size,
        .pCode = code
    };

    VkShaderModule module;
    vkCreateShaderModule(device, &ci, NULL, &module);
    free(code);

    return module;
}

bool vulkan_init(VulkanState *vk, size_t num_rays) {
    memset(vk, 0, sizeof(*vk));
    vk->buffer_size = num_rays * sizeof(float);

    /* Create instance */
    VkApplicationInfo app_info = {
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "Rake Vulkan Demo",
        .applicationVersion = VK_MAKE_VERSION(1, 0, 0),
        .pEngineName = "Rake",
        .engineVersion = VK_MAKE_VERSION(0, 2, 0),
        .apiVersion = VK_API_VERSION_1_2
    };

    VkInstanceCreateInfo inst_ci = {
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &app_info
    };

    if (vkCreateInstance(&inst_ci, NULL, &vk->instance) != VK_SUCCESS) {
        fprintf(stderr, "Failed to create Vulkan instance\n");
        return false;
    }

    /* Get physical device */
    uint32_t device_count = 0;
    vkEnumeratePhysicalDevices(vk->instance, &device_count, NULL);
    if (device_count == 0) {
        fprintf(stderr, "No Vulkan devices found\n");
        return false;
    }

    VkPhysicalDevice *devices = malloc(device_count * sizeof(VkPhysicalDevice));
    vkEnumeratePhysicalDevices(vk->instance, &device_count, devices);
    vk->physical_device = devices[0]; /* Use first device */
    free(devices);

    /* Print device name */
    VkPhysicalDeviceProperties props;
    vkGetPhysicalDeviceProperties(vk->physical_device, &props);
    printf("  Using GPU: %s\n", props.deviceName);

    /* Find compute queue family */
    uint32_t queue_count = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(vk->physical_device, &queue_count, NULL);
    VkQueueFamilyProperties *queues = malloc(queue_count * sizeof(VkQueueFamilyProperties));
    vkGetPhysicalDeviceQueueFamilyProperties(vk->physical_device, &queue_count, queues);

    vk->queue_family = UINT32_MAX;
    for (uint32_t i = 0; i < queue_count; i++) {
        if (queues[i].queueFlags & VK_QUEUE_COMPUTE_BIT) {
            vk->queue_family = i;
            break;
        }
    }
    free(queues);

    if (vk->queue_family == UINT32_MAX) {
        fprintf(stderr, "No compute queue found\n");
        return false;
    }

    /* Create logical device */
    float queue_priority = 1.0f;
    VkDeviceQueueCreateInfo queue_ci = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = vk->queue_family,
        .queueCount = 1,
        .pQueuePriorities = &queue_priority
    };

    VkDeviceCreateInfo device_ci = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &queue_ci
    };

    if (vkCreateDevice(vk->physical_device, &device_ci, NULL, &vk->device) != VK_SUCCESS) {
        fprintf(stderr, "Failed to create device\n");
        return false;
    }

    vkGetDeviceQueue(vk->device, vk->queue_family, 0, &vk->compute_queue);

    /* Create command pool and buffer */
    VkCommandPoolCreateInfo pool_ci = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .queueFamilyIndex = vk->queue_family,
        .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT
    };
    vkCreateCommandPool(vk->device, &pool_ci, NULL, &vk->command_pool);

    VkCommandBufferAllocateInfo cmd_ai = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = vk->command_pool,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1
    };
    vkAllocateCommandBuffers(vk->device, &cmd_ai, &vk->command_buffer);

    /* Create buffers */
    VkBufferCreateInfo buf_ci = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = vk->buffer_size,
        .usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE
    };

    /* 6 ray buffers + 1 sphere + 1 result = 8 buffers */
    size_t total_size = 0;
    VkMemoryRequirements mem_reqs;

    for (int i = 0; i < 6; i++) {
        vkCreateBuffer(vk->device, &buf_ci, NULL, &vk->ray_buffers[i]);
        vkGetBufferMemoryRequirements(vk->device, vk->ray_buffers[i], &mem_reqs);
        total_size += (mem_reqs.size + mem_reqs.alignment - 1) & ~(mem_reqs.alignment - 1);
    }

    buf_ci.size = sizeof(float) * 4; /* Sphere: cx, cy, cz, r */
    buf_ci.usage = VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT;
    vkCreateBuffer(vk->device, &buf_ci, NULL, &vk->sphere_buffer);
    vkGetBufferMemoryRequirements(vk->device, vk->sphere_buffer, &mem_reqs);
    total_size += (mem_reqs.size + mem_reqs.alignment - 1) & ~(mem_reqs.alignment - 1);

    buf_ci.size = vk->buffer_size;
    buf_ci.usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
    vkCreateBuffer(vk->device, &buf_ci, NULL, &vk->result_buffer);
    vkGetBufferMemoryRequirements(vk->device, vk->result_buffer, &mem_reqs);
    total_size += mem_reqs.size;

    /* Allocate memory */
    VkMemoryAllocateInfo mem_ai = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = total_size,
        .memoryTypeIndex = find_memory_type(vk->physical_device, mem_reqs.memoryTypeBits,
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)
    };
    vkAllocateMemory(vk->device, &mem_ai, NULL, &vk->memory);

    /* Bind buffers to memory */
    VkDeviceSize offset = 0;
    for (int i = 0; i < 6; i++) {
        vkBindBufferMemory(vk->device, vk->ray_buffers[i], vk->memory, offset);
        vkGetBufferMemoryRequirements(vk->device, vk->ray_buffers[i], &mem_reqs);
        offset += (mem_reqs.size + mem_reqs.alignment - 1) & ~(mem_reqs.alignment - 1);
    }

    vkBindBufferMemory(vk->device, vk->sphere_buffer, vk->memory, offset);
    vkGetBufferMemoryRequirements(vk->device, vk->sphere_buffer, &mem_reqs);
    offset += (mem_reqs.size + mem_reqs.alignment - 1) & ~(mem_reqs.alignment - 1);

    vkBindBufferMemory(vk->device, vk->result_buffer, vk->memory, offset);

    /* Create descriptor set layout */
    VkDescriptorSetLayoutBinding bindings[8];
    for (int i = 0; i < 6; i++) {
        bindings[i] = (VkDescriptorSetLayoutBinding){
            .binding = i,
            .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = 1,
            .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT
        };
    }
    bindings[6] = (VkDescriptorSetLayoutBinding){
        .binding = 6,
        .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        .descriptorCount = 1,
        .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT
    };
    bindings[7] = (VkDescriptorSetLayoutBinding){
        .binding = 7,
        .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        .descriptorCount = 1,
        .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT
    };

    VkDescriptorSetLayoutCreateInfo layout_ci = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = 8,
        .pBindings = bindings
    };
    vkCreateDescriptorSetLayout(vk->device, &layout_ci, NULL, &vk->descriptor_layout);

    /* Create descriptor pool and set */
    VkDescriptorPoolSize pool_sizes[] = {
        { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 7 },
        { VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1 }
    };

    VkDescriptorPoolCreateInfo desc_pool_ci = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .maxSets = 1,
        .poolSizeCount = 2,
        .pPoolSizes = pool_sizes
    };
    vkCreateDescriptorPool(vk->device, &desc_pool_ci, NULL, &vk->descriptor_pool);

    VkDescriptorSetAllocateInfo desc_ai = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = vk->descriptor_pool,
        .descriptorSetCount = 1,
        .pSetLayouts = &vk->descriptor_layout
    };
    vkAllocateDescriptorSets(vk->device, &desc_ai, &vk->descriptor_set);

    /* Update descriptor set */
    VkWriteDescriptorSet writes[8];
    VkDescriptorBufferInfo buffer_infos[8];

    for (int i = 0; i < 6; i++) {
        buffer_infos[i] = (VkDescriptorBufferInfo){
            .buffer = vk->ray_buffers[i],
            .offset = 0,
            .range = vk->buffer_size
        };
        writes[i] = (VkWriteDescriptorSet){
            .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = vk->descriptor_set,
            .dstBinding = i,
            .descriptorCount = 1,
            .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .pBufferInfo = &buffer_infos[i]
        };
    }

    buffer_infos[6] = (VkDescriptorBufferInfo){
        .buffer = vk->sphere_buffer,
        .offset = 0,
        .range = sizeof(float) * 4
    };
    writes[6] = (VkWriteDescriptorSet){
        .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .dstSet = vk->descriptor_set,
        .dstBinding = 6,
        .descriptorCount = 1,
        .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        .pBufferInfo = &buffer_infos[6]
    };

    buffer_infos[7] = (VkDescriptorBufferInfo){
        .buffer = vk->result_buffer,
        .offset = 0,
        .range = vk->buffer_size
    };
    writes[7] = (VkWriteDescriptorSet){
        .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .dstSet = vk->descriptor_set,
        .dstBinding = 7,
        .descriptorCount = 1,
        .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        .pBufferInfo = &buffer_infos[7]
    };

    vkUpdateDescriptorSets(vk->device, 8, writes, 0, NULL);

    /* Create pipeline layout with push constants */
    VkPushConstantRange push_range = {
        .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT,
        .offset = 0,
        .size = sizeof(uint32_t)
    };

    VkPipelineLayoutCreateInfo pipe_layout_ci = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 1,
        .pSetLayouts = &vk->descriptor_layout,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &push_range
    };
    vkCreatePipelineLayout(vk->device, &pipe_layout_ci, NULL, &vk->pipeline_layout);

    /* Load shader and create pipeline */
    VkShaderModule shader = load_shader(vk->device, "build/raytracer.spv");
    if (shader == VK_NULL_HANDLE) {
        fprintf(stderr, "Warning: Vulkan shader not found (build/raytracer.spv)\n");
        fprintf(stderr, "         GPU benchmark will be skipped.\n");
        vk->initialized = false;
        return false;
    }

    VkComputePipelineCreateInfo pipe_ci = {
        .sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
        .stage = {
            .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = VK_SHADER_STAGE_COMPUTE_BIT,
            .module = shader,
            .pName = "main"
        },
        .layout = vk->pipeline_layout
    };
    vkCreateComputePipelines(vk->device, VK_NULL_HANDLE, 1, &pipe_ci, NULL, &vk->pipeline);

    vkDestroyShaderModule(vk->device, shader, NULL);

    vk->initialized = true;
    return true;
}

void vulkan_cleanup(VulkanState *vk) {
    if (!vk->device) return;

    vkDeviceWaitIdle(vk->device);

    if (vk->pipeline) vkDestroyPipeline(vk->device, vk->pipeline, NULL);
    if (vk->pipeline_layout) vkDestroyPipelineLayout(vk->device, vk->pipeline_layout, NULL);
    if (vk->descriptor_pool) vkDestroyDescriptorPool(vk->device, vk->descriptor_pool, NULL);
    if (vk->descriptor_layout) vkDestroyDescriptorSetLayout(vk->device, vk->descriptor_layout, NULL);

    for (int i = 0; i < 6; i++) {
        if (vk->ray_buffers[i]) vkDestroyBuffer(vk->device, vk->ray_buffers[i], NULL);
    }
    if (vk->sphere_buffer) vkDestroyBuffer(vk->device, vk->sphere_buffer, NULL);
    if (vk->result_buffer) vkDestroyBuffer(vk->device, vk->result_buffer, NULL);
    if (vk->memory) vkFreeMemory(vk->device, vk->memory, NULL);

    if (vk->command_pool) vkDestroyCommandPool(vk->device, vk->command_pool, NULL);
    vkDestroyDevice(vk->device, NULL);
    vkDestroyInstance(vk->instance, NULL);
}

void vulkan_upload_rays(VulkanState *vk, RayPack *rays) {
    void *data;
    VkDeviceSize offset = 0;
    VkMemoryRequirements mem_reqs;

    float *ray_arrays[6] = { rays->ox, rays->oy, rays->oz, rays->dx, rays->dy, rays->dz };

    for (int i = 0; i < 6; i++) {
        vkMapMemory(vk->device, vk->memory, offset, vk->buffer_size, 0, &data);
        memcpy(data, ray_arrays[i], vk->buffer_size);
        vkUnmapMemory(vk->device, vk->memory);

        vkGetBufferMemoryRequirements(vk->device, vk->ray_buffers[i], &mem_reqs);
        offset += (mem_reqs.size + mem_reqs.alignment - 1) & ~(mem_reqs.alignment - 1);
    }
}

void vulkan_upload_sphere(VulkanState *vk, Sphere *sphere) {
    void *data;
    VkDeviceSize offset = 0;
    VkMemoryRequirements mem_reqs;

    /* Skip ray buffers */
    for (int i = 0; i < 6; i++) {
        vkGetBufferMemoryRequirements(vk->device, vk->ray_buffers[i], &mem_reqs);
        offset += (mem_reqs.size + mem_reqs.alignment - 1) & ~(mem_reqs.alignment - 1);
    }

    vkMapMemory(vk->device, vk->memory, offset, sizeof(float) * 4, 0, &data);
    float sphere_data[4] = { sphere->cx, sphere->cy, sphere->cz, sphere->r };
    memcpy(data, sphere_data, sizeof(sphere_data));
    vkUnmapMemory(vk->device, vk->memory);
}

void vulkan_dispatch(VulkanState *vk, uint32_t num_rays) {
    VkCommandBufferBeginInfo begin_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT
    };

    vkBeginCommandBuffer(vk->command_buffer, &begin_info);
    vkCmdBindPipeline(vk->command_buffer, VK_PIPELINE_BIND_POINT_COMPUTE, vk->pipeline);
    vkCmdBindDescriptorSets(vk->command_buffer, VK_PIPELINE_BIND_POINT_COMPUTE,
                           vk->pipeline_layout, 0, 1, &vk->descriptor_set, 0, NULL);
    vkCmdPushConstants(vk->command_buffer, vk->pipeline_layout,
                      VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof(uint32_t), &num_rays);

    uint32_t group_count = (num_rays + 255) / 256;
    vkCmdDispatch(vk->command_buffer, group_count, 1, 1);
    vkEndCommandBuffer(vk->command_buffer);

    VkSubmitInfo submit = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .commandBufferCount = 1,
        .pCommandBuffers = &vk->command_buffer
    };

    vkQueueSubmit(vk->compute_queue, 1, &submit, VK_NULL_HANDLE);
    vkQueueWaitIdle(vk->compute_queue);
}

void vulkan_download_result(VulkanState *vk, float *result) {
    void *data;
    VkDeviceSize offset = 0;
    VkMemoryRequirements mem_reqs;

    /* Skip ray + sphere buffers */
    for (int i = 0; i < 6; i++) {
        vkGetBufferMemoryRequirements(vk->device, vk->ray_buffers[i], &mem_reqs);
        offset += (mem_reqs.size + mem_reqs.alignment - 1) & ~(mem_reqs.alignment - 1);
    }
    vkGetBufferMemoryRequirements(vk->device, vk->sphere_buffer, &mem_reqs);
    offset += (mem_reqs.size + mem_reqs.alignment - 1) & ~(mem_reqs.alignment - 1);

    vkMapMemory(vk->device, vk->memory, offset, vk->buffer_size, 0, &data);
    memcpy(result, data, vk->buffer_size);
    vkUnmapMemory(vk->device, vk->memory);
}

void trace_vulkan(VulkanState *vk, RayPack *rays, Sphere *spheres, int num_spheres, float *result) {
    /* Initialize result to large values */
    for (int i = 0; i < NUM_RAYS; i++) result[i] = 1e30f;

    vulkan_upload_rays(vk, rays);

    for (int s = 0; s < num_spheres; s++) {
        vulkan_upload_sphere(vk, &spheres[s]);
        vulkan_dispatch(vk, NUM_RAYS);

        /* Download and merge */
        float *gpu_result = malloc(vk->buffer_size);
        vulkan_download_result(vk, gpu_result);

        for (int i = 0; i < NUM_RAYS; i++) {
            if (gpu_result[i] > 0.0f && gpu_result[i] < result[i]) {
                result[i] = gpu_result[i];
            }
        }
        free(gpu_result);
    }

    for (int i = 0; i < NUM_RAYS; i++) {
        if (result[i] > 1e29f) result[i] = -1.0f;
    }
}

/* Ray generation */
void generate_rays(RayPack *rays, int width, int height) {
    float aspect = (float)width / (float)height;
    float fov = 60.0f * M_PI / 180.0f;
    float half_height = tanf(fov / 2.0f);
    float half_width = aspect * half_height;

    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            int idx = y * width + x;

            rays->ox[idx] = 0.0f;
            rays->oy[idx] = 0.0f;
            rays->oz[idx] = 0.0f;

            float u = (2.0f * ((float)x + 0.5f) / (float)width - 1.0f) * half_width;
            float v = (1.0f - 2.0f * ((float)y + 0.5f) / (float)height) * half_height;

            float len = sqrtf(u * u + v * v + 1.0f);
            rays->dx[idx] = u / len;
            rays->dy[idx] = v / len;
            rays->dz[idx] = -1.0f / len;
        }
    }
}

/* Timing */
double get_time_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1000000.0;
}

/* Render to SDL surface */
void render_to_surface(SDL_Surface *surface, float *result, int width, int height) {
    uint32_t *pixels = surface->pixels;

    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            int idx = y * width + x;
            float t = result[idx];

            uint8_t r, g, b;
            if (t > 0.0f) {
                /* Depth-based coloring */
                float depth = 1.0f - (t - 3.0f) / 4.0f;
                depth = fmaxf(0.0f, fminf(1.0f, depth));
                r = (uint8_t)(50 + 180 * depth);
                g = (uint8_t)(80 + 150 * depth);
                b = (uint8_t)(120 + 100 * depth);
            } else {
                /* Background gradient */
                float grad = (float)y / height;
                r = (uint8_t)(20 + 30 * grad);
                g = (uint8_t)(20 + 40 * grad);
                b = (uint8_t)(40 + 60 * grad);
            }

            pixels[idx] = SDL_MapRGB(surface->format, r, g, b);
        }
    }
}

int main(int argc, char *argv[]) {
    (void)argc; (void)argv;

    printf("\n");
    printf("================================================================\n");
    printf("        Rake Raytracer - CPU SIMD vs GPU Compute Demo\n");
    printf("================================================================\n\n");

    /* Initialize SDL */
    if (SDL_Init(SDL_INIT_VIDEO) < 0) {
        fprintf(stderr, "SDL init failed: %s\n", SDL_GetError());
        return 1;
    }

    SDL_Window *window = SDL_CreateWindow("Rake Raytracer Demo",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        WIDTH, HEIGHT, SDL_WINDOW_SHOWN);
    if (!window) {
        fprintf(stderr, "Window creation failed: %s\n", SDL_GetError());
        return 1;
    }

    SDL_Surface *surface = SDL_GetWindowSurface(window);

    /* Allocate ray data */
    RayPack rays;
    rays.ox = aligned_alloc(32, NUM_RAYS * sizeof(float));
    rays.oy = aligned_alloc(32, NUM_RAYS * sizeof(float));
    rays.oz = aligned_alloc(32, NUM_RAYS * sizeof(float));
    rays.dx = aligned_alloc(32, NUM_RAYS * sizeof(float));
    rays.dy = aligned_alloc(32, NUM_RAYS * sizeof(float));
    rays.dz = aligned_alloc(32, NUM_RAYS * sizeof(float));
    float *result = aligned_alloc(32, NUM_RAYS * sizeof(float));

    generate_rays(&rays, WIDTH, HEIGHT);

    /* Setup spheres */
    Sphere spheres[NUM_SPHERES] = {
        { 0.0f, 0.0f, -5.0f, 1.0f },
        { -2.0f, 1.0f, -6.0f, 0.8f },
        { 2.0f, -0.5f, -4.5f, 0.6f },
        { -1.0f, -1.0f, -4.0f, 0.5f },
        { 1.5f, 1.2f, -7.0f, 1.2f }
    };

    /* Initialize Vulkan */
    VulkanState vk;
    bool have_vulkan = vulkan_init(&vk, NUM_RAYS);
    printf("\n");

    /* Benchmark */
    printf("Running benchmarks (10 iterations)...\n\n");
    const int BENCH_ITERS = 10;
    double scalar_time = 0, simd_time = 0, rake_time = 0, vulkan_time = 0;

    /* Warmup */
    trace_scalar(&rays, spheres, NUM_SPHERES, result);
    trace_simd(&rays, spheres, NUM_SPHERES, result);
    trace_rake(&rays, spheres, NUM_SPHERES, result);
    if (have_vulkan) trace_vulkan(&vk, &rays, spheres, NUM_SPHERES, result);

    /* C Scalar */
    double start = get_time_ms();
    for (int i = 0; i < BENCH_ITERS; i++) {
        trace_scalar(&rays, spheres, NUM_SPHERES, result);
    }
    scalar_time = (get_time_ms() - start) / BENCH_ITERS;

    /* C SIMD */
    start = get_time_ms();
    for (int i = 0; i < BENCH_ITERS; i++) {
        trace_simd(&rays, spheres, NUM_SPHERES, result);
    }
    simd_time = (get_time_ms() - start) / BENCH_ITERS;

    /* Rake SIMD */
    start = get_time_ms();
    for (int i = 0; i < BENCH_ITERS; i++) {
        trace_rake(&rays, spheres, NUM_SPHERES, result);
    }
    rake_time = (get_time_ms() - start) / BENCH_ITERS;

    /* Vulkan */
    if (have_vulkan) {
        start = get_time_ms();
        for (int i = 0; i < BENCH_ITERS; i++) {
            trace_vulkan(&vk, &rays, spheres, NUM_SPHERES, result);
        }
        vulkan_time = (get_time_ms() - start) / BENCH_ITERS;
    }

    /* Print results */
    printf("================================================================\n");
    printf("  BENCHMARK RESULTS (%dx%d, %d spheres)\n", WIDTH, HEIGHT, NUM_SPHERES);
    printf("================================================================\n");
    printf("  C Scalar:    %7.2f ms   (%.1f FPS)  baseline\n", scalar_time, 1000.0/scalar_time);
    printf("  C SIMD:      %7.2f ms   (%.1f FPS)  %.2fx speedup\n", simd_time, 1000.0/simd_time, scalar_time/simd_time);
    printf("  Rake SIMD:   %7.2f ms   (%.1f FPS)  %.2fx speedup\n", rake_time, 1000.0/rake_time, scalar_time/rake_time);
    if (have_vulkan) {
        printf("  Vulkan GPU:  %7.2f ms   (%.1f FPS)  %.2fx speedup\n", vulkan_time, 1000.0/vulkan_time, scalar_time/vulkan_time);
    }
    printf("================================================================\n");
    printf("\n");

    /* Interactive visualization */
    printf("Controls:\n");
    printf("  1 = C Scalar    2 = C SIMD    3 = Rake SIMD");
    if (have_vulkan) printf("    4 = Vulkan GPU");
    printf("\n");
    printf("  Q = Quit\n\n");

    int mode = 3; /* Start with Rake */
    bool running = true;
    float time_offset = 0.0f;

    while (running) {
        SDL_Event event;
        while (SDL_PollEvent(&event)) {
            if (event.type == SDL_QUIT) running = false;
            if (event.type == SDL_KEYDOWN) {
                switch (event.key.keysym.sym) {
                    case SDLK_q: case SDLK_ESCAPE: running = false; break;
                    case SDLK_1: mode = 1; break;
                    case SDLK_2: mode = 2; break;
                    case SDLK_3: mode = 3; break;
                    case SDLK_4: if (have_vulkan) mode = 4; break;
                }
            }
        }

        /* Animate spheres */
        time_offset += 0.02f;
        Sphere animated[NUM_SPHERES];
        for (int i = 0; i < NUM_SPHERES; i++) {
            animated[i] = spheres[i];
            animated[i].cx += 0.5f * sinf(time_offset + i * 1.2f);
            animated[i].cy += 0.3f * cosf(time_offset * 0.7f + i * 0.8f);
        }

        /* Trace */
        double frame_start = get_time_ms();
        switch (mode) {
            case 1: trace_scalar(&rays, animated, NUM_SPHERES, result); break;
            case 2: trace_simd(&rays, animated, NUM_SPHERES, result); break;
            case 3: trace_rake(&rays, animated, NUM_SPHERES, result); break;
            case 4: if (have_vulkan) trace_vulkan(&vk, &rays, animated, NUM_SPHERES, result); break;
        }
        double frame_time = get_time_ms() - frame_start;

        /* Render */
        render_to_surface(surface, result, WIDTH, HEIGHT);

        /* Draw mode indicator */
        SDL_Rect indicator = { 10, 10, 150, 25 };
        uint32_t colors[] = { 0x804040, 0x408040, 0x4040A0, 0xA04080 };
        SDL_FillRect(surface, &indicator, colors[mode - 1]);

        SDL_UpdateWindowSurface(window);

        /* Update title with FPS */
        char title[128];
        const char *mode_names[] = { "C Scalar", "C SIMD (AVX2)", "Rake SIMD", "Vulkan GPU" };
        snprintf(title, sizeof(title), "Rake Raytracer - %s - %.1f FPS (%.1f ms)",
                 mode_names[mode - 1], 1000.0 / frame_time, frame_time);
        SDL_SetWindowTitle(window, title);
    }

    /* Cleanup */
    if (have_vulkan) vulkan_cleanup(&vk);

    free(rays.ox); free(rays.oy); free(rays.oz);
    free(rays.dx); free(rays.dy); free(rays.dz);
    free(result);

    SDL_DestroyWindow(window);
    SDL_Quit();

    return 0;
}
