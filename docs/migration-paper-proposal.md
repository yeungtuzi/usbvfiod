# Migration paper proposal: discussion notes

# Abstract

When a virtual machine is migrated between hosts, the expected goal is that the guest can continue running with as little visible disruption as possible. For device state that is fully modeled and managed inside the VMM, the migration boundary is relatively clear: the VMM can define which state has to be saved and restored together with the VM. However, things become more complicated when the VM relies on external devices or host-side backends. In such cases, some of the state required for the guest to continue using the device may be stored in the physical device, the host kernel, or a separate backend process, rather than inside the VMM itself. Therefore, migration also has to consider how this external device-related state and the corresponding connection to the guest can be preserved, restored, or re-established.

This issue is not unique to USB devices; it also appears with typical passthrough or accelerator devices such as GPUs, where migration support depends on how device-specific state is exposed to the virtualization stack. USB devices are interesting because they connect this general problem with a broader set of device exposure options. Some of these options overlap with generic mechanisms such as VFIO, vfio-user, or VirtIO-style device models, while others are more USB-specific, including emulated USB controllers, userspace backends such as usbvfiod, and USB/IP-based approaches. This makes USB a useful case for examining where migration-relevant state is located and how different exposure paths affect the design of migration support.

Cloud Hypervisor is a suitable platform for exploring this direction, since it already provides VM migration support and includes several ways of exposing devices to guests. The thesis will therefore treat generic passthrough migration mainly as background, and will instead focus on how the current USB device exposure options relate to migration support. The main target will be the usbvfiod path, where the USB device model is provided by a userspace backend and used together with a VMM such as Cloud Hypervisor. In this setting, migration support cannot be implemented only on one side: usbvfiod needs to define and expose the state required to migrate the USB device model, while the VMM stack needs to integrate this state into its save and restore flow.

The thesis will first provide an overview of relevant device exposure mechanisms, including VFIO, vfio-user, and VirtIO-style device models, with a focus on how far their live migration support currently reaches and which gaps remain. Based on this overview, the main investigation will focus on the usbvfiod path: what migration-relevant state exists there, where this state is located, and how it should be exposed, saved, restored, or reconnected during migration. Since usbvfiod has to be used together with a VMM, the work will examine the interaction between usbvfiod and Cloud Hypervisor, and may also consider QEMU/KVM as an alternative virtualization stack if its more mature migration infrastructure provides a better basis for prototyping or comparison. In addition, the thesis will investigate whether cross-host migration is feasible for USB devices in the selected setup. Since USB devices are physical objects attached to a specific host, it is not yet clear whether they can be migrated transparently in the same way as purely virtual devices. If cross-host migration is feasible, the work will examine how the device connection and the required backend state can be preserved or re-established across hosts. If it turns out to be impractical or impossible in the selected setup, the thesis will analyze where the limiting factors are, what requirements cannot be met, and whether a same-host migration scenario or a more limited form of migration support would be a realistic alternative.

# Concrete Plan

## Tentative Title

**Migration of External Device State in Virtual Machines: A Case Study with usbvfiod and Cloud Hypervisor**

## Motivation and Problem

VM migration is not only about moving CPU and memory when part of the guest-visible device behavior is implemented by an external backend. The migration boundary must also include, or correctly reconstruct, the state needed by that backend.


 ![](attachments/64e9a635-5ffb-487d-a92d-95f68ed5519c.png " =1047x131")

### **Concrete example: USB flash drive**

The guest is actively reading from or writing to a USB flash drive through usbvfiod when migration starts.

* Cloud Hypervisor can migrate the VM, but usbvfiod may still hold xHCI/controller and transfer-related state.
* Host-side USB access is tied to local resources that cannot simply be copied as raw process state.
* The destination therefore needs both the correct logical backend state and valid access to a USB resource.

**question:** after migration, can the guest continue using the virtual controller correctly (follow-up: can keep using the usb devices), without lost/duplicated I/O or unnecessary disconnect/re-enumeration?

**question:** effect of failed migration/rollback (continue on migration source)

**Core thesis idea**

Use the existing vfio-user migration model as the baseline, identify what usbvfiod-specific state and behavior are required, determine what support is missing in usbvfiod / rust-vmm / Cloud Hypervisor, implement the required path, and evaluate it.

## Related Work

| **Component** | **Current situation** | **Role in the thesis** |
|-----------|-------------------|--------------------|
| QEMU      | implement vfio-user migration | Reference          |
| Cloud Hypervisor | VM-level live migration exists | Existing infrastructure |
| vfio-user | Migration states/data-transfer semantics exist | Protocol baseline  |
| CH vfio-user migration integration | Exact upstream support boundary still to be established | Early feasibility analysis |
| usbvfiod  | No migration implementation | Main case study / implementation target |
| VFIO / vhost-user | Existing device/backend migration examples in CH | Design references only |

## Research Questions


1. How is migration-relevant state handled when a VM uses an external device or userspace backend, and what requirements arise when this state is not fully managed by the VMM?
2. How can migration support for an external USB backend such as usbvfiod be designed and integrated into Cloud Hypervisor's existing migration framework?
3. To what extent can the proposed mechanism preserve correct device operation across VM migration, and what limitations remain?
4. Under what conditions is migration of a VM using a physical external device feasible, and what limitations are introduced by the physical device and host-specific resources?

## Design

(main work)


1. Analyze the existing vfio-user migration support

   
   1. vfio-user migration specification
   2. relevant draft PR of CHV / rust-vmm  
   3. vfio-user migration implementation in QEMU, as reference
2. Identify the migration-relevant state for usbvfiod
3. Design how to preserve and restore usbvfiod state 

(Additional Work)


1. Analyze usbvfiod ↔ Linux kernel / physical USB migration
2. Design physical-device migration mechanism

## Implementation


1. Implement the CHV ↔ usbvfiod controller migration path through vfio-user

   
   1. in CHV/vfio-user
   2. in usbvfiod
2. If time remains: implement usbvfiod ↔ Linux kernel part

## Evaluation


1. Does vfio-user successfully migrate the state required by usbvfiod? 
2. Is the restored state correct?
3. Does it work for same-host and cross-host?
4. What limitations remain?

## Future Work

USB/IP: <https://hackweek.opensuse.org/projects/usb-storage-plumbing-for-the-linux-kernel-library> mentions a mostly-stubbed virtio-usb host-side driver and early guest kernel-side virtio-usb driver work. The design direction appears to reuse USB/IP and vhci-hcd as much as same-host? cross-host? possible, while replacing the TCP-based USB/IP transport with VirtIO transport logic

## Conclusions

## Timeline

| **Period** | **Main focus** | **Expected result** |
|--------|------------|-----------------|
| Weeks 1-4 | Analyze & Research | Existing-support map; state inventory; requirements; final scope/RQs, start Thesis draft! |
| Weeks 5-10 | Design     | Migration lifecycle; state format; quiescing; resource handling; integration design |
| Weeks 11-14 | Implementation | usbvfiod migration behavior + required vfio-user/CHV integration; working prototype |
| Weeks 15-18 | Evaluation/Extend | Functional/I/O correctness; continuity; downtime; limitations/failure tests; or other extension if core work finishes early |
| Weeks 19-22 | Cleanup    | Finish Thesis writing/Presentation preparing |


\