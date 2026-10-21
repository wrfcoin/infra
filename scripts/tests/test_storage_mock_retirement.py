"""Retirement guards inspect tracked deployment sources; no live daemon calls."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).parents[2]


def read(file):
    return (ROOT / file).read_text()


def test_legacy_service_and_gateway_are_absent():
    for file in ["testnet/docker-compose.testnet.yml", "testnet/docker-compose.local-paths.yml",
                 "testnet/docker-compose.override.yml",
                 "testnet/edge/route-ledger.yml", "testnet/PUBLIC_ENDPOINTS.md"]:
        assert "wrfcoin-storage" not in read(file), file
    assert "wrfcoin-testnet-storage:7000" not in read("testnet/edge/Caddyfile.internal")


def test_image_entry_and_source_fixture_cannot_reintroduce_mock():
    for file in ["infra/docker/esbuild-backend.sh", "scripts/tests/fixtures/esbuild-entries/backend-tree.txt"]:
        assert "storage_networks_server" not in read(file), file


def test_boot_smoke_and_readiness_do_not_probe_retired_service():
    smoke = read("testnet/scripts/smoke-full.sh")
    assert 'verify_service_preflight "wrfcoin-storage"' not in smoke
    assert 'run_functional_probe "Storage" "storage"' not in smoke
    assert 'wait_for_health "Storage"' not in smoke
    assert "storage|http://127.0.0.1:7000" not in read("scripts/testnet-launch-readiness.sh")
    assert '"storage": {' not in read("testnet/scripts/full-profile-functional-probe.py")


def test_development_orchestrators_do_not_launch_missing_backend_mocks():
    for file in ["scripts/dag-orchestrator.js", "scripts/service-control-panel.js",
                 "scripts/enhanced-service-control-panel.js", "scripts/integrate-rate-limiting.js",
                 "scripts/resilience-scorecard.js"]:
        for source in ["storage_networks_server.js", "nas_storage_server.js", "nas_storage_server.ts"]:
            assert source not in read(file), (file, source)


def test_legacy_nas_images_and_deployments_cannot_launch_deleted_sources():
    for file in ["infra/docker/Dockerfile.nas", "infra/docker/docker-compose.nas.yml"]:
        assert not (ROOT / file).exists(), file
    assert "wrf-storage-node:" not in read("infra/deployment/unraid/docker-compose.secure.yml")
    for file in ["infra/k8s/base/deployment.yaml", "infra/k8s/base/services.yaml",
                 "infra/k8s/base/ingress.yaml"]:
        assert "wrfcoin-storage" not in read(file), file


def test_legacy_nas_view_refuses_without_daemon_io():
    # Compile the actual class; omit imports, constructor and listener bootstrap.
    code = r'''
const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict');
const source = fs.readFileSync(process.argv[1], 'utf8');
const begin = source.indexOf('class EnhancedServiceControlPanel');
const end = source.indexOf('// Start the enhanced control panel', begin);
assert.ok(begin >= 0 && end > begin);
let calls = 0;
const axios = { get() { calls++; throw new Error('unexpected IO'); }, post() { calls++; throw new Error('unexpected IO'); } };
const Panel = vm.runInNewContext(source.slice(begin, end) + ';EnhancedServiceControlPanel', { axios });
const panel = Object.create(Panel.prototype);
const routes = new Map();
panel.app = { get(path, handler) { routes.set(path, handler); }, post(path, handler) { routes.set(path, handler); } };
panel.setupRoutes();
for (const path of ['/api/nas/nodes', '/api/nas/discovery', '/api/nas/register', '/api/earnings/summary']) {
  let result;
  routes.get(path)({ body: { synthetic: true } }, { json(value) { result = value; } });
  assert.equal(result.success, false, path);
  assert.equal(result.unavailable, true, path);
  assert.equal(typeof result.then, 'undefined', 'direct res.json callers require a plain result');
}
assert.equal(calls, 0);
const html = panel.generateEnhancedControlPanelHTML();
assert.match(html, /disabled>NAS discovery unavailable/);
const elements = new Map();
const document = { getElementById(id) {
  if (!elements.has(id)) elements.set(id, { textContent: '', innerHTML: '' });
  return elements.get(id);
} };
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
const context = vm.createContext({ document, console, setInterval() {}, fetch() { throw new Error('unexpected browser IO'); } });
// Exercise the actual rendering functions without the page's initial polling.
vm.runInContext(script.replace(/\n\s*loadData\(\);\s*$/, ''), context);
context.retired = panel.getNASNodesStatus();
vm.runInContext('renderStorage(retired)', context);
assert.match(elements.get('storage-content').textContent, /retired/);
context.fetch = async () => ({ json: async () => panel.getEarningsSummary() });
vm.runInContext('loadEarnings()', context).then(() => {
  assert.match(elements.get('earnings-content').textContent, /unavailable/);
});
'''
    subprocess.run(["node", "-e", code, str(ROOT / "scripts/enhanced-service-control-panel.js")],
                   check=True, text=True, capture_output=True, timeout=5)
