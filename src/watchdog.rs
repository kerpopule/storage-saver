//! Process-local scan watchdog. Only the scan command opts into fail-stop behavior.
use std::{
    sync::mpsc::{Receiver, RecvTimeoutError},
    time::Duration,
};

pub enum Pulse {
    Working(Duration),
    Finished,
}

pub fn watch(rx: Receiver<Pulse>, initial: Duration, stalled: impl FnOnce()) {
    let mut timeout = initial;
    loop {
        match rx.recv_timeout(timeout) {
            Ok(Pulse::Working(next)) => timeout = next,
            Ok(Pulse::Finished) | Err(RecvTimeoutError::Disconnected) => return,
            Err(RecvTimeoutError::Timeout) => {
                stalled();
                return;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{sync::mpsc, thread, time::Instant};
    #[test]
    fn silent_scan_is_bounded() {
        let (_tx, rx) = mpsc::channel();
        let start = Instant::now();
        let mut expired = false;
        watch(rx, Duration::from_millis(40), || expired = true);
        assert!(expired);
        assert!(start.elapsed() < Duration::from_secs(1));
    }
    #[test]
    fn heartbeat_extends_lifetime_and_finish_cancels() {
        let (tx, rx) = mpsc::channel();
        let worker = thread::spawn(move || {
            for _ in 0..4 {
                tx.send(Pulse::Working(Duration::from_millis(200))).unwrap();
                thread::sleep(Duration::from_millis(30));
            }
            tx.send(Pulse::Finished).unwrap();
        });
        watch(rx, Duration::from_millis(200), || {
            panic!("active scanner timed out")
        });
        worker.join().unwrap();
    }
    #[test]
    fn errors_and_dropped_owner_do_not_leave_watchdog_alive() {
        let (tx, rx) = mpsc::channel();
        drop(tx);
        watch(rx, Duration::from_secs(60), || {
            panic!("disconnected owner timed out")
        });
    }
}
