//! Share a single [`XhciBackend`] between several vfio-user client connections.
//!
//! usbvfiod historically served exactly one vfio-user client and exited when it
//! disconnected. During a same-host live migration the destination VMM connects
//! while the source is still connected, which a single-`accept()` server cannot
//! serve: the destination blocks forever in the vfio-user version handshake and
//! the migration never completes.
//!
//! The handshake commands (`Version`, `DeviceGetInfo`, `DeviceGetRegionInfo`,
//! `GetIrqInfo`) never touch the backend, whereas the data path commands
//! (`RegionRead`/`RegionWrite`/`DmaMap`/`DmaUnmap`/`SetIrqs`/`DeviceReset`) do.
//! This wrapper therefore takes the backend lock **per command** instead of per
//! connection, so a second client can complete its handshake while the first
//! one is still connected.
//!
//! The device state itself (xHCI registers, slots, endpoints) lives in the
//! shared backend and therefore survives the client hand-over. With
//! `memory_mode=memfds` both VMMs map the same guest memory file, so the DMA
//! mappings remain valid as well.

use std::{
    fs::File,
    sync::{Arc, Mutex, MutexGuard},
};

use vfio_user::{DmaMapFlags, DmaUnmapFlags, ServerBackend};

use crate::{device::xhci::real_device::CompleteRealDevice, xhci_backend::XhciBackend};

/// Serialises access to one [`XhciBackend`] for any number of vfio-user clients.
#[derive(Debug)]
pub struct SharedBackend<CRD: CompleteRealDevice> {
    inner: Arc<Mutex<XhciBackend<CRD>>>,
}

impl<CRD: CompleteRealDevice> SharedBackend<CRD> {
    pub const fn new(inner: Arc<Mutex<XhciBackend<CRD>>>) -> Self {
        Self { inner }
    }

    fn backend(&self) -> MutexGuard<'_, XhciBackend<CRD>> {
        // A panicking client must not take the whole controller down, so
        // recover from a poisoned mutex rather than propagating the panic.
        self.inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

impl<CRD: CompleteRealDevice> ServerBackend for SharedBackend<CRD> {
    fn region_read(
        &mut self,
        region: u32,
        offset: u64,
        data: &mut [u8],
    ) -> Result<(), std::io::Error> {
        self.backend().region_read(region, offset, data)
    }

    fn region_write(
        &mut self,
        region: u32,
        offset: u64,
        data: &[u8],
    ) -> Result<(), std::io::Error> {
        self.backend().region_write(region, offset, data)
    }

    fn dma_map(
        &mut self,
        flags: DmaMapFlags,
        offset: u64,
        address: u64,
        size: u64,
        fd: Option<File>,
    ) -> Result<(), std::io::Error> {
        self.backend().dma_map(flags, offset, address, size, fd)
    }

    fn dma_unmap(
        &mut self,
        flags: DmaUnmapFlags,
        address: u64,
        size: u64,
    ) -> Result<(), std::io::Error> {
        self.backend().dma_unmap(flags, address, size)
    }

    fn reset(&mut self) -> Result<(), std::io::Error> {
        self.backend().reset()
    }

    fn set_irqs(
        &mut self,
        index: u32,
        flags: u32,
        start: u32,
        count: u32,
        fds: Vec<File>,
    ) -> Result<(), std::io::Error> {
        self.backend().set_irqs(index, flags, start, count, fds)
    }
}
