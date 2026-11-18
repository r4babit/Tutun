package app.tutun
import org.junit.Assert.*
import org.junit.Test
class RecoveryDeferralTests {
    @Test fun networkBurstWaitsForNewUserSnapshotThenRecoversOnce() {
        val gate = VpnSessionGate(); val pending = RecoveryDeferral(); val ticket = gate.start()
        pending.begin(ticket)
        assertTrue(pending.deferIfStarting(gate::accepts)); assertTrue(pending.deferIfStarting(gate::accepts))
        assertTrue(gate.accepts(ticket)); assertTrue(pending.finish(ticket)); assertFalse(pending.finish(ticket))
    }
    @Test fun staleStartCannotClearNewPendingCommand() {
        val gate = VpnSessionGate(); val pending = RecoveryDeferral(); val old = gate.start(); pending.begin(old)
        val fresh = gate.start(); pending.begin(fresh); pending.deferIfStarting(gate::accepts)
        assertFalse(pending.finish(old)); assertTrue(pending.finish(fresh))
    }
    @Test fun manualStopDropsDeferredRecovery() {
        val gate = VpnSessionGate(); val pending = RecoveryDeferral(); val ticket = gate.start(); pending.begin(ticket)
        pending.deferIfStarting(gate::accepts); gate.stop(); pending.cancel()
        assertFalse(pending.finish(ticket)); assertFalse(pending.deferIfStarting(gate::accepts))
    }
}
