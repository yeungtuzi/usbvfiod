use std::{
    fs::File,
    io::Write,
    path::Path,
    sync::{Arc, Mutex},
};

use anyhow::{anyhow, Context, Result};
use nusb::MaybeFuture;
use tokio::runtime;
use tracing::{debug, info, trace, warn};

use usbvfiod::hotplug_protocol::{device_paths::resolve_path, response::Response};
use vfio_bindings::bindings::vfio::{
    vfio_region_info, VFIO_PCI_BAR0_REGION_INDEX, VFIO_PCI_BAR1_REGION_INDEX,
    VFIO_PCI_BAR2_REGION_INDEX, VFIO_PCI_BAR3_REGION_INDEX, VFIO_PCI_BAR4_REGION_INDEX,
    VFIO_PCI_BAR5_REGION_INDEX, VFIO_PCI_CONFIG_REGION_INDEX, VFIO_PCI_MSIX_IRQ_INDEX,
    VFIO_PCI_NUM_IRQS, VFIO_PCI_NUM_REGIONS, VFIO_REGION_INFO_FLAG_READ,
    VFIO_REGION_INFO_FLAG_WRITE,
};
use vfio_user::{IrqInfo, ServerBackend, ServerRegion};

use crate::device::{
    bus::{Request, RequestSize},
    interrupt_line::{DummyInterruptLine, InterruptLine},
    pci::{traits::PciDevice, xhci::XhciController},
    xhci::{
        nusb::NusbRealDevice,
        port::HotplugControl,
        real_device::{CompleteRealDevice, CompleteRealDeviceImpl},
    },
};

use crate::{dynamic_bus::DynamicBus, memory_segment::MemorySegment};

#[derive(Debug)]
pub struct XhciBackend<CRD: CompleteRealDevice> {
    dma_bus: Arc<DynamicBus>,
    controller: XhciController<CRD>,
}

#[derive(Debug)]
struct InterruptEventFd {
    /// TODO: Get rid of the Mutex. Writes to the EventFd are safe.
    ///  This just satisfies the Send + Sync requirements and provides
    ///  interior mutability for the [`InterruptLine`] trait.
    fd: Mutex<File>,
}

impl InterruptLine for InterruptEventFd {
    fn interrupt(&self) {
        // Ensure all guest memory modifications can be observed by another process.
        // The sequentially consistent fence emits a hardware memory barrier operation.
        std::sync::atomic::fence(std::sync::atomic::Ordering::SeqCst);

        // Write any 8 byte value to the EventFd.
        // TODO: we just expect this to always work currently.
        let _amount = self
            .fd
            .lock()
            .unwrap()
            .write(&1u64.to_le_bytes())
            .expect("should always be able to write event fd");
    }
}

impl<CRD: CompleteRealDevice> XhciBackend<CRD> {
    /// Create a new virtual XHCI controller with the given USB
    /// devices attached at creation time.
    pub fn new(async_runtime: runtime::Handle) -> Result<Self> {
        let dma_bus = Arc::new(DynamicBus::new());
        let controller = XhciController::new(dma_bus.clone(), async_runtime);

        let backend = Self {
            controller,
            dma_bus,
        };

        Ok(backend)
    }

    pub fn hotplug_control(&self) -> HotplugControl<CRD> {
        self.controller.hotplug_control()
    }
}

impl XhciBackend<CompleteRealDeviceImpl<NusbRealDevice, (u8, u8)>> {
    pub async fn add_device_from_path(
        &self,
        path: impl AsRef<Path>,
        async_runtime: runtime::Handle,
    ) -> Result<()> {
        let (bus, dev, path) = resolve_path(path)?;
        let open_file = |err_msg| {
            std::fs::OpenOptions::new()
                .read(true)
                .write(true)
                .open(&path)
                .with_context(|| format!("{}: {}", err_msg, path.display()))
        };

        let file = open_file("Failed to open USB device file")?;
        let device = nusb::Device::from_fd(file.into()).wait()?;
        device.reset().wait()?;

        // After the reset, the device instance is no longer usable and we need
        // to reopen.
        let file = open_file("Failed to open USB device file after device reset")?;
        let device = nusb::Device::from_fd(file.into()).wait()?;
        let real_device = NusbRealDevice::try_new(device, async_runtime.clone())?;
        let complete_device = CompleteRealDeviceImpl::new((bus, dev), real_device);
        let response = self.hotplug_control().attach(complete_device).await;
        if response != Response::SuccessfulOperation {
            return Err(anyhow!(
                "initial attach of device {bus:03}:{dev:03} failed: {response:?}"
            ));
        }

        Ok(())
    }
}

impl<CRD: CompleteRealDevice> XhciBackend<CRD> {
    /// Return a list of regions for [`vfio_user::Server::new`].
    pub fn regions(&self) -> Vec<ServerRegion> {
        (0..VFIO_PCI_NUM_REGIONS)
            .map(|i| {
                let empty_region = ServerRegion {
                    region_info: vfio_region_info {
                        argsz: size_of::<vfio_region_info>() as u32,
                        index: i,
                        ..Default::default()
                    },
                    sparse_areas: vec![],
                    mmap_fd: None,
                };

                match i {
                    VFIO_PCI_CONFIG_REGION_INDEX => {
                        debug!("Client queried config space region");

                        ServerRegion {
                            region_info: vfio_region_info {
                                argsz: size_of::<vfio_region_info>() as u32,
                                index: i,
                                size: 256,
                                flags: VFIO_REGION_INFO_FLAG_READ | VFIO_REGION_INFO_FLAG_WRITE,
                                ..Default::default()
                            },
                            sparse_areas: vec![],
                            mmap_fd: None,
                        }
                    }

                    VFIO_PCI_BAR0_REGION_INDEX
                    | VFIO_PCI_BAR1_REGION_INDEX
                    | VFIO_PCI_BAR2_REGION_INDEX
                    | VFIO_PCI_BAR3_REGION_INDEX
                    | VFIO_PCI_BAR4_REGION_INDEX
                    | VFIO_PCI_BAR5_REGION_INDEX => {
                        let bar_no = i - VFIO_PCI_BAR0_REGION_INDEX;

                        u8::try_from(bar_no)
                            .ok()
                            .and_then(|bar_no| self.controller.bar(bar_no))
                            .map_or_else(
                                || {
                                    debug!("Client queried BAR{bar_no} region: (empty)");
                                    empty_region
                                },
                                |bar_info| {
                                    debug!("Client queried BAR{bar_no} region: {:?}", bar_info);
                                    ServerRegion {
                                        region_info: vfio_region_info {
                                            argsz: size_of::<vfio_region_info>() as u32,
                                            index: i,
                                            size: bar_info.size.into(),
                                            flags: VFIO_REGION_INFO_FLAG_READ
                                                | VFIO_REGION_INFO_FLAG_WRITE,
                                            ..Default::default()
                                        },
                                        sparse_areas: vec![],
                                        mmap_fd: None,
                                    }
                                },
                            )
                    }

                    unknown => {
                        debug!("Client queried unknown VFIO region: {unknown}");
                        empty_region
                    }
                }
            })
            .collect()
    }

    /// Return a list of IRQs for [`vfio_user::Server::new`].
    pub fn irqs(&self) -> Vec<IrqInfo> {
        (0..VFIO_PCI_NUM_IRQS)
            .map(|index| IrqInfo {
                index,
                count: match index {
                    VFIO_PCI_MSIX_IRQ_INDEX => 1,
                    _ => 0,
                },
                flags: 0,
            })
            .collect()
    }
}

impl<CRD: CompleteRealDevice> ServerBackend for XhciBackend<CRD> {
    fn region_read(
        &mut self,
        region: u32,
        offset: u64,
        data: &mut [u8],
    ) -> Result<(), std::io::Error> {
        // Sizes come from a client request, so they are validated rather than
        // assumed: a malformed request must not panic a connection thread.
        let size = RequestSize::try_from(data.len() as u64)
            .map_err(|_| std::io::Error::other("unsupported region read size"))?;

        let value: u64 = match region {
            VFIO_PCI_CONFIG_REGION_INDEX => self.controller.read_cfg(Request::new(offset, size)),
            0 => self.controller.read_io(0, Request::new(offset, size)),
            _ => !0u64,
        };

        let bytes = value.to_le_bytes();
        if data.len() > bytes.len() {
            return Err(std::io::Error::other("unsupported region read size"));
        }
        data.copy_from_slice(&bytes[0..data.len()]);

        trace!(
            "read region {region} offset {offset:#x}+{} val {:?}",
            data.len(),
            data
        );

        Ok(())
    }

    fn region_write(
        &mut self,
        region: u32,
        offset: u64,
        data: &[u8],
    ) -> Result<(), std::io::Error> {
        trace!(
            "write region {region} offset {offset:#x}+{} val {:?}",
            data.len(),
            data
        );

        let size = RequestSize::try_from(data.len() as u64)
            .map_err(|_| std::io::Error::other("unsupported region write size"))?;

        let value: u64 = match data.len() {
            1 => data[0].into(),
            2 => {
                // SAFETY: this branch is only taken if data.len() == 2
                let val: [u8; 2] = data.try_into().unwrap();
                u16::from_le_bytes(val).into()
            }
            4 => {
                // SAFETY: this branch is only taken if data.len() == 4
                let val: [u8; 4] = data.try_into().unwrap();
                u32::from_le_bytes(val).into()
            }
            _ => return Err(std::io::Error::other("unsupported region write size")),
        };

        match region {
            VFIO_PCI_CONFIG_REGION_INDEX => {
                self.controller.write_cfg(Request::new(offset, size), value);
            }
            0 => self
                .controller
                .write_io(0, Request::new(offset, size), value),
            _ => return Err(std::io::Error::other("unsupported region write")),
        }

        Ok(())
    }

    fn dma_map(
        &mut self,
        flags: vfio_user::DmaMapFlags,
        offset: u64,
        address: u64,
        size: u64,
        fd: Option<File>,
    ) -> Result<(), std::io::Error> {
        info!("dma_map flags = {flags:?} offset = {offset} address = {address} size = {size} fd = {fd:?}");

        if let Some(fd) = fd {
            let flags = flags
                .try_into()
                .map_err(|_| std::io::Error::other("unsupported DMA map flags"))?;
            let mseg = MemorySegment::new_from_fd(&fd, offset, size, flags)?;

            // A reconnecting client (e.g. the destination VMM taking over the
            // device after a live migration) re-maps the very same guest memory
            // range, so replace a previous mapping at this address instead of
            // failing with an overlap error.
            self.dma_bus.add(address, Arc::new(mseg)).map_err(|err| {
                std::io::Error::other(format!("failed to map DMA region at {address:#x}: {err}"))
            })?;
        } else {
            return Err(std::io::Error::other(
                "DMA region without file descriptor is not supported",
            ));
        }

        Ok(())
    }

    fn dma_unmap(
        &mut self,
        _flags: vfio_user::DmaUnmapFlags,
        address: u64,
        size: u64,
    ) -> Result<(), std::io::Error> {
        debug!("dma_unmap address = {address:#x} size = {size:#x}");

        self.dma_bus.remove_range(address, size).map_err(|err| {
            std::io::Error::other(format!("failed to unmap DMA region at {address:#x}: {err}"))
        })
    }

    fn reset(&mut self) -> Result<(), std::io::Error> {
        // usbvfiod advertises itself as not resettable, and avoiding device
        // resets is the entire point of the suspend/migration work (R4).
        // Answer explicitly instead of panicking if a client asks anyway.
        warn!("ignoring VFIO_USER_DEVICE_RESET request (device is not resettable)");
        Err(std::io::Error::other("device reset is not supported"))
    }

    fn set_irqs(
        &mut self,
        index: u32,
        flags: u32,
        start: u32,
        count: u32,
        fds: Vec<File>,
    ) -> Result<(), std::io::Error> {
        debug!(
            "set IRQs: {index} flags: {flags:#x} start: {start:#x} count: {count:#x} #fds: {}",
            fds.len()
        );
        // Return errors rather than panicking: the request comes from a client
        // connection, and a malformed request must not take the thread (or the
        // controller) down.
        if index != VFIO_PCI_MSIX_IRQ_INDEX {
            return Err(std::io::Error::other("only MSI-X interrupts are supported"));
        }
        if count > 1 {
            return Err(std::io::Error::other(
                "only a single interrupt is supported",
            ));
        }

        let irqs: Vec<Arc<InterruptEventFd>> = fds
            .into_iter()
            .map(|file| {
                Arc::new(InterruptEventFd {
                    fd: Mutex::new(file),
                })
            })
            .collect();

        // The solution offered by clippy produces a type error.
        #[allow(clippy::option_if_let_else)]
        let irq: Arc<dyn InterruptLine> = match irqs.first() {
            Some(eventfd) => eventfd.clone(),
            _ => Arc::new(DummyInterruptLine::default()),
        };

        // Test hook (debug builds only): widen the hand-over window
        // deterministically. The new line is handed to the interrupter worker
        // only after this call returns, so while we sleep here the worker keeps
        // draining completion events onto the *departing* client's interrupt
        // line - exactly the window the kick exists to cover. Without the hook
        // that window is a few milliseconds of luck; with it every injection run
        // is exposed by construction, which turns "the kick covers the window"
        // from an anecdote into a controlled comparison.
        #[cfg(debug_assertions)]
        if !irqs.is_empty() {
            if let Some(ms) = std::env::var("USBVFIOD_INJECT_HANDOVER_DELAY_MS")
                .ok()
                .and_then(|v| v.parse::<u64>().ok())
            {
                warn!(
                    "TEST HOOK: delaying hand-over line install by {ms} ms \
                     (USBVFIOD_INJECT_HANDOVER_DELAY_MS)"
                );
                std::thread::sleep(std::time::Duration::from_millis(ms));
            }
        }

        // Note: the interrupter itself raises one interrupt when it installs a
        // new line. Only the interrupter's own worker can order that kick
        // against the event messages that were queued before the hand-over, so
        // the kick must not be issued from this thread.
        self.controller.connect_irq(Arc::clone(&irq));

        Ok(())
    }
}
