/// Vulkan GPU Operations
///
/// Provides Vulkan compute shader operations for hardware-accelerated encoding
/// on Linux and Windows platforms where Metal is unavailable.
///
/// This module handles Vulkan device management, buffer allocation, queue
/// selection, and compute pipeline construction.
///
/// All code in this file is guarded by `#if canImport(Vulkan)` and is only
/// compiled when the Vulkan SDK SwiftPM package is present. The entire
/// `Hardware/Vulkan/` directory can be deleted and all `#if canImport(Vulkan)`
/// call-site branches removed to strip Vulkan support without affecting any
/// other platform.

#if canImport(Vulkan)
import Vulkan
import Foundation

/// Vulkan GPU operations for hardware-accelerated image encoding.
///
/// Mirrors the `MetalOps` API shape so that the `GPUCompute` abstraction
/// layer can route between Metal and Vulkan transparently.
public enum VulkanOps {

    // MARK: - Instance & Device Management

    /// Shared Vulkan instance (lazy-initialised).
    private nonisolated(unsafe) static var _instance: VkInstance?
    private static let instanceLock = NSLock()

    /// Shared physical device (lazy-initialised).
    private nonisolated(unsafe) static var _physicalDevice: VkPhysicalDevice?

    /// Shared logical device (lazy-initialised).
    private nonisolated(unsafe) static var _device: VkDevice?
    private static let deviceLock = NSLock()

    /// Compute queue family index.
    private nonisolated(unsafe) static var _computeQueueFamily: UInt32 = UInt32.max

    /// Shared compute queue (lazy-initialised).
    private nonisolated(unsafe) static var _computeQueue: VkQueue?
    private static let queueLock = NSLock()

    /// Whether Vulkan is available on this system.
    public static var isAvailable: Bool {
        return device() != nil
    }

    /// Get (or lazily create) the Vulkan logical device.
    ///
    /// - Returns: The `VkDevice` handle, or `nil` if Vulkan initialisation fails.
    public static func device() -> VkDevice? {
        deviceLock.lock()
        defer { deviceLock.unlock() }

        if _device == nil {
            _device = createDevice()
        }
        return _device
    }

    /// Human-readable device name for logging and diagnostics.
    public static var deviceName: String {
        guard isAvailable,
              let physDev = _physicalDevice else {
            return "Not Available"
        }
        var props = VkPhysicalDeviceProperties()
        vkGetPhysicalDeviceProperties(physDev, &props)
        return withUnsafeBytes(of: props.deviceName) { rawBuf in
            let bytes = rawBuf.bindMemory(to: CChar.self)
            return String(cString: bytes.baseAddress!)
        }
    }

    // MARK: - Command Pool & Queue

    /// Shared command pool for compute operations.
    private nonisolated(unsafe) static var _commandPool: VkCommandPool?
    private static let poolLock = NSLock()

    /// Get (or lazily create) the compute command pool.
    ///
    /// - Returns: A `VkCommandPool`, or `nil` if creation fails.
    public static func commandPool() -> VkCommandPool? {
        poolLock.lock()
        defer { poolLock.unlock() }

        if _commandPool == nil {
            guard let dev = device() else { return nil }
            var poolInfo = VkCommandPoolCreateInfo()
            poolInfo.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO
            poolInfo.queueFamilyIndex = _computeQueueFamily
            poolInfo.flags = UInt32(VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT.rawValue)
            var pool: VkCommandPool?
            guard vkCreateCommandPool(dev, &poolInfo, nil, &pool) == VK_SUCCESS else { return nil }
            _commandPool = pool
        }
        return _commandPool
    }

    /// Get the compute queue.
    ///
    /// - Returns: The `VkQueue` for compute operations, or `nil` if unavailable.
    public static func computeQueue() -> VkQueue? {
        queueLock.lock()
        defer { queueLock.unlock() }

        if _computeQueue == nil {
            guard let dev = device() else { return nil }
            var queue: VkQueue?
            vkGetDeviceQueue(dev, _computeQueueFamily, 0, &queue)
            _computeQueue = queue
        }
        return _computeQueue
    }

    // MARK: - Descriptor Pool

    /// Shared descriptor pool for compute pipelines.
    private nonisolated(unsafe) static var _descriptorPool: VkDescriptorPool?
    private static let descriptorPoolLock = NSLock()

    /// Get (or lazily create) the descriptor pool.
    ///
    /// - Returns: A `VkDescriptorPool`, or `nil` if creation fails.
    public static func descriptorPool() -> VkDescriptorPool? {
        descriptorPoolLock.lock()
        defer { descriptorPoolLock.unlock() }

        if _descriptorPool == nil {
            guard let dev = device() else { return nil }
            let poolSize = VkDescriptorPoolSize(
                type: VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                descriptorCount: 32
            )
            var sizes = [poolSize]
            var poolInfo = VkDescriptorPoolCreateInfo()
            poolInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO
            poolInfo.maxSets = 16
            poolInfo.poolSizeCount = 1
            poolInfo.pPoolSizes = sizes.withUnsafeBufferPointer { $0.baseAddress }
            var pool: VkDescriptorPool?
            guard vkCreateDescriptorPool(dev, &poolInfo, nil, &pool) == VK_SUCCESS else { return nil }
            _descriptorPool = pool
        }
        return _descriptorPool
    }

    // MARK: - Buffer Management

    /// Allocate a Vulkan device-local / host-visible buffer.
    ///
    /// - Parameters:
    ///   - length: Buffer size in bytes.
    /// - Returns: A `VulkanBuffer` wrapping the `VkBuffer` and its `VkDeviceMemory`, or `nil` on failure.
    public static func makeBuffer(length: Int) -> VulkanBuffer? {
        guard let dev = device(),
              let physDev = _physicalDevice else { return nil }

        var bufInfo = VkBufferCreateInfo()
        bufInfo.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO
        bufInfo.size = VkDeviceSize(length)
        bufInfo.usage = UInt32(VK_BUFFER_USAGE_STORAGE_BUFFER_BIT.rawValue)
        bufInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE

        var buffer: VkBuffer?
        guard vkCreateBuffer(dev, &bufInfo, nil, &buffer) == VK_SUCCESS,
              let buf = buffer else { return nil }

        var memReqs = VkMemoryRequirements()
        vkGetBufferMemoryRequirements(dev, buf, &memReqs)

        guard let memTypeIndex = findMemoryType(
            physDev: physDev,
            typeBits: memReqs.memoryTypeBits,
            properties: UInt32(VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT.rawValue |
                               VK_MEMORY_PROPERTY_HOST_COHERENT_BIT.rawValue)
        ) else {
            vkDestroyBuffer(dev, buf, nil)
            return nil
        }

        var allocInfo = VkMemoryAllocateInfo()
        allocInfo.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
        allocInfo.allocationSize = memReqs.size
        allocInfo.memoryTypeIndex = memTypeIndex

        var memory: VkDeviceMemory?
        guard vkAllocateMemory(dev, &allocInfo, nil, &memory) == VK_SUCCESS,
              let mem = memory else {
            vkDestroyBuffer(dev, buf, nil)
            return nil
        }

        guard vkBindBufferMemory(dev, buf, mem, 0) == VK_SUCCESS else {
            vkFreeMemory(dev, mem, nil)
            vkDestroyBuffer(dev, buf, nil)
            return nil
        }

        return VulkanBuffer(device: dev, buffer: buf, memory: mem, length: length)
    }

    /// Upload host data into a Vulkan buffer.
    ///
    /// - Parameters:
    ///   - data: Source data as raw bytes.
    ///   - buffer: Destination `VulkanBuffer`.
    public static func uploadData<T>(_ data: [T], to buffer: VulkanBuffer) {
        guard let dev = device() else { return }
        var mapped: UnsafeMutableRawPointer?
        guard vkMapMemory(dev, buffer.memory, 0, VkDeviceSize(buffer.length), 0, &mapped) == VK_SUCCESS,
              let ptr = mapped else { return }
        let byteCount = data.count * MemoryLayout<T>.stride
        _ = data.withUnsafeBytes { src in
            memcpy(ptr, src.baseAddress!, min(byteCount, buffer.length))
        }
        vkUnmapMemory(dev, buffer.memory)
    }

    /// Download data from a Vulkan buffer into a Swift array.
    ///
    /// - Parameters:
    ///   - buffer: Source `VulkanBuffer`.
    ///   - count: Number of elements of type `T` to read.
    /// - Returns: An array of `count` elements, or `nil` on failure.
    public static func downloadData<T>(_ buffer: VulkanBuffer, count: Int) -> [T]? {
        guard let dev = device() else { return nil }
        var mapped: UnsafeMutableRawPointer?
        guard vkMapMemory(dev, buffer.memory, 0, VkDeviceSize(buffer.length), 0, &mapped) == VK_SUCCESS,
              let ptr = mapped else { return nil }
        let result = Array(UnsafeBufferPointer(
            start: ptr.assumingMemoryBound(to: T.self),
            count: count
        ))
        vkUnmapMemory(dev, buffer.memory)
        return result
    }

    // MARK: - Compute Pipeline Cache

    /// Cache of compute pipelines keyed by shader entry-point name.
    private nonisolated(unsafe) static var pipelineCache: [String: VulkanPipeline] = [:]
    private static let pipelineLock = NSLock()

    /// Get or create a compute pipeline for the given SPIR-V shader entry point.
    ///
    /// - Parameters:
    ///   - name: Shader entry-point name used as cache key.
    ///   - spirvData: Compiled SPIR-V bytecode for the compute shader.
    /// - Returns: A `VulkanPipeline`, or `nil` if creation fails.
    public static func computePipeline(
        named name: String,
        spirv spirvData: [UInt32]
    ) -> VulkanPipeline? {
        pipelineLock.lock()
        defer { pipelineLock.unlock() }

        if let cached = pipelineCache[name] { return cached }

        guard let dev = device() else { return nil }

        // Create shader module
        var shaderInfo = VkShaderModuleCreateInfo()
        shaderInfo.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO
        shaderInfo.codeSize = spirvData.count * MemoryLayout<UInt32>.stride
        var spirvCopy = spirvData
        shaderInfo.pCode = spirvCopy.withUnsafeBufferPointer { $0.baseAddress }

        var shaderModule: VkShaderModule?
        guard vkCreateShaderModule(dev, &shaderInfo, nil, &shaderModule) == VK_SUCCESS,
              let module = shaderModule else { return nil }

        // Create descriptor set layout (4 storage buffers)
        let bindings: [VkDescriptorSetLayoutBinding] = (0..<4).map { idx in
            VkDescriptorSetLayoutBinding(
                binding: UInt32(idx),
                descriptorType: VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                descriptorCount: 1,
                stageFlags: UInt32(VK_SHADER_STAGE_COMPUTE_BIT.rawValue),
                pImmutableSamplers: nil
            )
        }
        var layoutInfo = VkDescriptorSetLayoutCreateInfo()
        layoutInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
        layoutInfo.bindingCount = UInt32(bindings.count)
        var bindingsCopy = bindings
        layoutInfo.pBindings = bindingsCopy.withUnsafeBufferPointer { $0.baseAddress }

        var descriptorSetLayout: VkDescriptorSetLayout?
        guard vkCreateDescriptorSetLayout(dev, &layoutInfo, nil, &descriptorSetLayout) == VK_SUCCESS,
              let layout = descriptorSetLayout else {
            vkDestroyShaderModule(dev, module, nil)
            return nil
        }

        // Create pipeline layout
        var pipelineLayoutInfo = VkPipelineLayoutCreateInfo()
        pipelineLayoutInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO
        pipelineLayoutInfo.setLayoutCount = 1
        var layoutCopy = layout
        pipelineLayoutInfo.pSetLayouts = withUnsafePointer(to: &layoutCopy) { $0 }

        var pipelineLayout: VkPipelineLayout?
        guard vkCreatePipelineLayout(dev, &pipelineLayoutInfo, nil, &pipelineLayout) == VK_SUCCESS,
              let pLayout = pipelineLayout else {
            vkDestroyDescriptorSetLayout(dev, layout, nil)
            vkDestroyShaderModule(dev, module, nil)
            return nil
        }

        // Create compute pipeline
        var entryName = name.utf8CString
        var stageInfo = VkPipelineShaderStageCreateInfo()
        stageInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
        stageInfo.stage = VK_SHADER_STAGE_COMPUTE_BIT
        stageInfo.module = module
        stageInfo.pName = entryName.withUnsafeBufferPointer { $0.baseAddress }

        var pipelineInfo = VkComputePipelineCreateInfo()
        pipelineInfo.sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO
        pipelineInfo.layout = pLayout
        pipelineInfo.stage = stageInfo

        var pipeline: VkPipeline?
        guard vkCreateComputePipelines(dev, nil, 1, &pipelineInfo, nil, &pipeline) == VK_SUCCESS,
              let vkPipeline = pipeline else {
            vkDestroyPipelineLayout(dev, pLayout, nil)
            vkDestroyDescriptorSetLayout(dev, layout, nil)
            vkDestroyShaderModule(dev, module, nil)
            return nil
        }

        vkDestroyShaderModule(dev, module, nil)

        let vulkanPipeline = VulkanPipeline(
            device: dev,
            pipeline: vkPipeline,
            layout: pLayout,
            descriptorSetLayout: layout
        )
        pipelineCache[name] = vulkanPipeline
        return vulkanPipeline
    }

    // MARK: - Command Execution

    /// Submit a single compute dispatch and wait for completion.
    ///
    /// - Parameters:
    ///   - pipeline: The compute pipeline to use.
    ///   - descriptors: Buffer descriptors (index → `VulkanBuffer`).
    ///   - groupCountX: Number of workgroups in X.
    ///   - groupCountY: Number of workgroups in Y.
    ///   - groupCountZ: Number of workgroups in Z.
    /// - Returns: `true` on success, `false` on any Vulkan error.
    @discardableResult
    public static func dispatch(
        pipeline: VulkanPipeline,
        descriptors: [Int: VulkanBuffer],
        groupCountX: UInt32,
        groupCountY: UInt32,
        groupCountZ: UInt32 = 1
    ) -> Bool {
        guard let dev = device(),
              let pool = commandPool(),
              let queue = computeQueue(),
              let descPool = descriptorPool() else { return false }

        // Allocate descriptor set
        var allocInfo = VkDescriptorSetAllocateInfo()
        allocInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO
        allocInfo.descriptorPool = descPool
        allocInfo.descriptorSetCount = 1
        var layoutCopy = pipeline.descriptorSetLayout
        allocInfo.pSetLayouts = withUnsafePointer(to: &layoutCopy) { $0 }

        var descriptorSet: VkDescriptorSet?
        guard vkAllocateDescriptorSets(dev, &allocInfo, &descriptorSet) == VK_SUCCESS,
              let descSet = descriptorSet else { return false }

        // Write buffer descriptors
        var writes: [VkWriteDescriptorSet] = []
        var bufInfos: [VkDescriptorBufferInfo] = []
        for (binding, buf) in descriptors.sorted(by: { $0.key < $1.key }) {
            bufInfos.append(VkDescriptorBufferInfo(
                buffer: buf.buffer,
                offset: 0,
                range: VkDeviceSize(buf.length)
            ))
            var write = VkWriteDescriptorSet()
            write.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
            write.dstSet = descSet
            write.dstBinding = UInt32(binding)
            write.descriptorCount = 1
            write.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER
            writes.append(write)
        }
        // Assign buffer info pointers after array is stable
        for i in writes.indices {
            bufInfos.withUnsafeBufferPointer { ptr in
                writes[i].pBufferInfo = ptr.baseAddress?.advanced(by: i)
            }
        }
        vkUpdateDescriptorSets(dev, UInt32(writes.count), &writes, 0, nil)

        // Allocate and record command buffer
        var cmdAllocInfo = VkCommandBufferAllocateInfo()
        cmdAllocInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
        cmdAllocInfo.commandPool = pool
        cmdAllocInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY
        cmdAllocInfo.commandBufferCount = 1

        var cmdBuffer: VkCommandBuffer?
        guard vkAllocateCommandBuffers(dev, &cmdAllocInfo, &cmdBuffer) == VK_SUCCESS,
              let cmd = cmdBuffer else { return false }

        var beginInfo = VkCommandBufferBeginInfo()
        beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
        beginInfo.flags = UInt32(VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT.rawValue)

        guard vkBeginCommandBuffer(cmd, &beginInfo) == VK_SUCCESS else {
            vkFreeCommandBuffers(dev, pool, 1, &cmdBuffer)
            return false
        }

        var pipelineCopy = pipeline.pipeline
        var pipelineLayoutCopy = pipeline.layout
        var descSetCopy = descSet
        vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, pipelineCopy)
        vkCmdBindDescriptorSets(
            cmd, VK_PIPELINE_BIND_POINT_COMPUTE, pipelineLayoutCopy,
            0, 1, &descSetCopy, 0, nil
        )
        vkCmdDispatch(cmd, groupCountX, groupCountY, groupCountZ)

        guard vkEndCommandBuffer(cmd) == VK_SUCCESS else {
            vkFreeCommandBuffers(dev, pool, 1, &cmdBuffer)
            return false
        }

        // Submit and wait
        var submitInfo = VkSubmitInfo()
        submitInfo.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO
        submitInfo.commandBufferCount = 1
        var cmdCopy = cmd
        submitInfo.pCommandBuffers = withUnsafePointer(to: &cmdCopy) { $0 }

        var fence: VkFence?
        var fenceInfo = VkFenceCreateInfo()
        fenceInfo.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO
        guard vkCreateFence(dev, &fenceInfo, nil, &fence) == VK_SUCCESS,
              let f = fence else {
            vkFreeCommandBuffers(dev, pool, 1, &cmdBuffer)
            return false
        }

        let submitResult = vkQueueSubmit(queue, 1, &submitInfo, f)
        if submitResult == VK_SUCCESS {
            vkWaitForFences(dev, 1, &fence, VK_TRUE, UInt64.max)
        }
        vkDestroyFence(dev, f, nil)
        vkFreeCommandBuffers(dev, pool, 1, &cmdBuffer)
        vkFreeDescriptorSets(dev, descPool, 1, &descriptorSet)

        return submitResult == VK_SUCCESS
    }

    // MARK: - Resource Cleanup

    /// Release all cached Vulkan resources.
    ///
    /// Call this during application shutdown or when freeing GPU memory.
    public static func cleanup() {
        pipelineLock.lock()
        if let dev = _device {
            for (_, pipeline) in pipelineCache {
                vkDestroyPipeline(dev, pipeline.pipeline, nil)
                vkDestroyPipelineLayout(dev, pipeline.layout, nil)
                vkDestroyDescriptorSetLayout(dev, pipeline.descriptorSetLayout, nil)
            }
        }
        pipelineCache.removeAll()
        pipelineLock.unlock()

        poolLock.lock()
        if let dev = _device, let pool = _commandPool {
            vkDestroyCommandPool(dev, pool, nil)
        }
        _commandPool = nil
        poolLock.unlock()

        descriptorPoolLock.lock()
        if let dev = _device, let pool = _descriptorPool {
            vkDestroyDescriptorPool(dev, pool, nil)
        }
        _descriptorPool = nil
        descriptorPoolLock.unlock()

        deviceLock.lock()
        if let dev = _device {
            vkDestroyDevice(dev, nil)
        }
        _device = nil
        _physicalDevice = nil
        deviceLock.unlock()

        instanceLock.lock()
        if let inst = _instance {
            vkDestroyInstance(inst, nil)
        }
        _instance = nil
        instanceLock.unlock()
    }

    // MARK: - Private Helpers

    /// Create the Vulkan instance, select a physical device, and create a logical device.
    private static func createDevice() -> VkDevice? {
        // Create Vulkan instance
        var appInfo = VkApplicationInfo()
        appInfo.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO
        appInfo.pApplicationName = "JXLSwift"
        appInfo.applicationVersion = VK_MAKE_VERSION(1, 0, 0)
        appInfo.pEngineName = "JXLSwift"
        appInfo.engineVersion = VK_MAKE_VERSION(1, 0, 0)
        appInfo.apiVersion = VK_API_VERSION_1_2

        var instInfo = VkInstanceCreateInfo()
        instInfo.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
        instInfo.pApplicationInfo = withUnsafePointer(to: &appInfo) { $0 }

        var instance: VkInstance?
        guard vkCreateInstance(&instInfo, nil, &instance) == VK_SUCCESS,
              let inst = instance else { return nil }
        _instance = inst

        // Enumerate physical devices
        var deviceCount: UInt32 = 0
        vkEnumeratePhysicalDevices(inst, &deviceCount, nil)
        guard deviceCount > 0 else { return nil }

        var physDevices = [VkPhysicalDevice?](repeating: nil, count: Int(deviceCount))
        vkEnumeratePhysicalDevices(inst, &deviceCount, &physDevices)

        // Select the first device that has a compute queue
        for physDevOpt in physDevices {
            guard let physDev = physDevOpt else { continue }
            if let queueFamily = findComputeQueueFamily(physDev: physDev) {
                _physicalDevice = physDev
                _computeQueueFamily = queueFamily
                return createLogicalDevice(physDev: physDev, queueFamily: queueFamily)
            }
        }
        return nil
    }

    /// Find a queue family that supports compute operations.
    private static func findComputeQueueFamily(physDev: VkPhysicalDevice) -> UInt32? {
        var queueCount: UInt32 = 0
        vkGetPhysicalDeviceQueueFamilyProperties(physDev, &queueCount, nil)
        guard queueCount > 0 else { return nil }

        var queues = [VkQueueFamilyProperties](
            repeating: VkQueueFamilyProperties(),
            count: Int(queueCount)
        )
        vkGetPhysicalDeviceQueueFamilyProperties(physDev, &queueCount, &queues)

        for (index, props) in queues.enumerated() {
            if props.queueFlags & UInt32(VK_QUEUE_COMPUTE_BIT.rawValue) != 0 {
                return UInt32(index)
            }
        }
        return nil
    }

    /// Create a Vulkan logical device for the chosen physical device and queue family.
    private static func createLogicalDevice(
        physDev: VkPhysicalDevice,
        queueFamily: UInt32
    ) -> VkDevice? {
        let priority: Float = 1.0
        var queueCreateInfo = VkDeviceQueueCreateInfo()
        queueCreateInfo.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO
        queueCreateInfo.queueFamilyIndex = queueFamily
        queueCreateInfo.queueCount = 1
        queueCreateInfo.pQueuePriorities = withUnsafePointer(to: priority) { $0 }

        var deviceInfo = VkDeviceCreateInfo()
        deviceInfo.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO
        deviceInfo.queueCreateInfoCount = 1
        deviceInfo.pQueueCreateInfos = withUnsafePointer(to: &queueCreateInfo) { $0 }

        var device: VkDevice?
        guard vkCreateDevice(physDev, &deviceInfo, nil, &device) == VK_SUCCESS else { return nil }
        return device
    }

    /// Find a memory type index satisfying the given property flags.
    private static func findMemoryType(
        physDev: VkPhysicalDevice,
        typeBits: UInt32,
        properties: UInt32
    ) -> UInt32? {
        var memProps = VkPhysicalDeviceMemoryProperties()
        vkGetPhysicalDeviceMemoryProperties(physDev, &memProps)

        for i in 0..<UInt32(memProps.memoryTypeCount) {
            let typeMatch = (typeBits & (1 << i)) != 0
            // Note: accessing memoryTypes tuple elements requires index-based access in checkMemoryType
            if typeMatch && checkMemoryType(memProps: &memProps, index: i, flags: properties) {
                return i
            }
        }
        return nil
    }

    private static func checkMemoryType(
        memProps: inout VkPhysicalDeviceMemoryProperties,
        index: UInt32,
        flags: UInt32
    ) -> Bool {
        withUnsafeBytes(of: &memProps.memoryTypes) { rawBuf in
            let types = rawBuf.bindMemory(to: VkMemoryType.self)
            guard Int(index) < types.count else { return false }
            return (types[Int(index)].propertyFlags & flags) == flags
        }
    }
}

// MARK: - VulkanBuffer

/// A Vulkan buffer with its associated device memory.
///
/// Manages the lifetime of a `VkBuffer` + `VkDeviceMemory` pair.
/// Must be explicitly destroyed via `destroy()` or the owning scope's cleanup.
public final class VulkanBuffer: @unchecked Sendable {
    let device: VkDevice
    let buffer: VkBuffer
    let memory: VkDeviceMemory
    /// Byte length of this buffer.
    public let length: Int

    init(device: VkDevice, buffer: VkBuffer, memory: VkDeviceMemory, length: Int) {
        self.device = device
        self.buffer = buffer
        self.memory = memory
        self.length = length
    }

    /// Release Vulkan resources for this buffer.
    public func destroy() {
        vkDestroyBuffer(device, buffer, nil)
        vkFreeMemory(device, memory, nil)
    }

    deinit {
        destroy()
    }
}

// MARK: - VulkanPipeline

/// A Vulkan compute pipeline with its associated layout and descriptor set layout.
public final class VulkanPipeline: @unchecked Sendable {
    let device: VkDevice
    let pipeline: VkPipeline
    let layout: VkPipelineLayout
    let descriptorSetLayout: VkDescriptorSetLayout

    init(
        device: VkDevice,
        pipeline: VkPipeline,
        layout: VkPipelineLayout,
        descriptorSetLayout: VkDescriptorSetLayout
    ) {
        self.device = device
        self.pipeline = pipeline
        self.layout = layout
        self.descriptorSetLayout = descriptorSetLayout
    }
}

#endif // canImport(Vulkan)
