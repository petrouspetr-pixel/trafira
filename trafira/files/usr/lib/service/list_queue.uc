// The short gate closes the request-versus-worker-release race. Worker locks
// are shared by list updates and snapshot preparation, and survive as inodes.
let fs = require("fs");
function create(worker_path, pending_path) {
    let worker = null;
    let last_error = "";
    function gate() {
        let file = fs.open(worker_path + ".requests", "ae", 384);
        if (!file) { last_error = "queue_unavailable"; return null; }
        if (!file.lock("x")) { last_error = "queue_unavailable"; file.close(); return null; }
        return file;
    }
    function begin(request) {
        last_error = "";
        let guard = gate();
        if (!guard) return false;
        if (request) {
            let pending = fs.open(pending_path, "w", 384);
            if (!pending) { last_error = "queue_unavailable"; guard.close(); return false; }
            let ok = pending.write("1") == 1;
            pending.close();
            if (!ok) { last_error = "queue_unavailable"; guard.close(); return false; }
        }
        let file = fs.open(worker_path, "ae", 384);
        if (!file || !file.lock("xn")) {
            if (!file) last_error = "queue_unavailable";
            if (file) file.close();
            guard.close(); return false;
        }
        worker = file;
        if (request && !fs.unlink(pending_path)) {
            last_error = "queue_unavailable"; worker.close(); worker = null;
            guard.close(); return false;
        }
        guard.close(); return true;
    }
    function end(schedule) {
        let guard = gate();
        // On gate failure release the worker; the durable pending marker stays.
        if (worker) { worker.close(); worker = null; }
        if (!guard) return false;
        let pending = fs.lstat(pending_path) != null;
        guard.close();
        return !pending || schedule();
    }
    return { begin, end, error: () => last_error };
}
return { create };
