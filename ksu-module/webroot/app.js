const MODDIR = "/data/adb/modules/nohello-demo";
const files = {
	targets: `${MODDIR}/target_path.conf`,
	hideDirents: `${MODDIR}/hide_dirents.conf`,
	scope: `${MODDIR}/scope_mode.conf`,
	denyPackages: `${MODDIR}/deny_packages.conf`,
	denyUids: `${MODDIR}/deny_uids.conf`,
	service: `${MODDIR}/service.sh`,
};

let ksuApi = null;
let apps = [];
let selectedPackages = new Set();

const $ = (selector) => document.querySelector(selector);
const pathList = $("#pathList");
const appList = $("#appList");
const statusText = $("#statusText");
const toast = $("#toast");

try {
	ksuApi = await import("kernelsu");
} catch {
	ksuApi = null;
}

function shellQuote(value) {
	return `'${String(value).replace(/'/g, "'\\''")}'`;
}

async function execShell(command) {
	if (!ksuApi?.exec) {
		throw new Error("KernelSU WebUI API is not available");
	}
	const result = await ksuApi.exec(command);
	if (result.errno && result.errno !== 0) {
		throw new Error(result.stderr || result.stdout || `Command failed: ${result.errno}`);
	}
	return result.stdout || "";
}

function showToast(message) {
	toast.textContent = message;
	toast.hidden = false;
	clearTimeout(showToast.timer);
	showToast.timer = setTimeout(() => {
		toast.hidden = true;
	}, 2600);
}

async function readFile(path) {
	return execShell(`[ -f ${shellQuote(path)} ] && cat ${shellQuote(path)} || true`);
}

async function writeLines(path, lines) {
	const clean = lines.map((line) => line.trim()).filter(Boolean);
	const body = clean.length
		? `printf '%s\\n' ${clean.map(shellQuote).join(" ")} > ${shellQuote(path)}`
		: `: > ${shellQuote(path)}`;
	await execShell(`mkdir -p ${shellQuote(MODDIR)}; ${body}`);
}

function linesFromText(text) {
	return text.split(/\r?\n/)
		.map((line) => line.trim())
		.filter((line) => line && !line.startsWith("#"));
}

function renderPaths(paths) {
	pathList.textContent = "";
	const list = paths.length ? paths : ["/data/local/tmp/nohello"];
	for (const path of list) {
		const row = document.createElement("div");
		row.className = "pathRow";
		const input = document.createElement("input");
		input.type = "text";
		input.value = path;
		const remove = document.createElement("button");
		remove.type = "button";
		remove.textContent = "Del";
		remove.addEventListener("click", () => {
			row.remove();
		});
		row.append(input, remove);
		pathList.append(row);
	}
}

function collectPaths() {
	return [...pathList.querySelectorAll("input")]
		.map((input) => input.value.trim())
		.filter(Boolean);
}

function parsePackageLine(line) {
	const match = line.match(/^package:(.+?)\s+uid:(\d+)$/);
	if (!match) return null;
	return { pkg: match[1], uid: match[2] };
}

function renderApps() {
	const query = $("#searchInput").value.trim().toLowerCase();
	appList.textContent = "";

	const filtered = apps.filter((app) => !query || app.pkg.toLowerCase().includes(query));
	for (const app of filtered) {
		const row = document.createElement("label");
		row.className = "appRow";

		const checkbox = document.createElement("input");
		checkbox.type = "checkbox";
		checkbox.checked = selectedPackages.has(app.pkg);
		checkbox.addEventListener("change", () => {
			if (checkbox.checked) selectedPackages.add(app.pkg);
			else selectedPackages.delete(app.pkg);
		});

		const pkg = document.createElement("div");
		pkg.className = "pkg";
		pkg.textContent = app.pkg;

		const uid = document.createElement("div");
		uid.className = "uid";
		uid.textContent = app.uid;

		row.append(checkbox, pkg, uid);
		appList.append(row);
	}
}

async function loadApps() {
	const showSystem = $("#showSystemInput").checked;
	const command = showSystem ? "pm list packages -U" : "pm list packages -U -3";
	const output = await execShell(command);
	apps = output.split(/\r?\n/)
		.map(parsePackageLine)
		.filter(Boolean)
		.sort((a, b) => a.pkg.localeCompare(b.pkg));
	renderApps();
	showToast(`Loaded ${apps.length} apps`);
}

async function refreshConfig() {
	const targetText = await readFile(files.targets);
	const hideText = await readFile(files.hideDirents);
	const scopeText = await readFile(files.scope);
	const pkgText = await readFile(files.denyPackages);
	const uidText = await readFile(files.denyUids);
	const procText = await execShell("grep '^nohello ' /proc/modules || true");

	renderPaths(linesFromText(targetText));
	$("#hideDirentsInput").checked = (hideText.trim() || "1") !== "0";
	const scope = (scopeText.trim() || "global") === "deny" ? "deny" : "global";
	document.querySelector(`input[name="scope"][value="${scope}"]`).checked = true;
	selectedPackages = new Set(linesFromText(pkgText));
	$("#denyUidsInput").value = linesFromText(uidText).join("\n");
	statusText.textContent = procText.trim() ? "Module loaded" : "Module not loaded";
	renderApps();
}

async function saveConfig() {
	const scope = document.querySelector('input[name="scope"]:checked')?.value || "global";
	await writeLines(files.targets, collectPaths());
	await writeLines(files.hideDirents, [$("#hideDirentsInput").checked ? "1" : "0"]);
	await writeLines(files.scope, [scope]);
	await writeLines(files.denyPackages, [...selectedPackages].sort());
	await writeLines(files.denyUids, linesFromText($("#denyUidsInput").value));
	showToast("Saved");
}

async function reloadModule() {
	await saveConfig();
	statusText.textContent = "Reloading...";
	await execShell(
		`if grep -q '^nohello ' /proc/modules 2>/dev/null; then rmmod nohello; fi; sh ${shellQuote(files.service)}; dmesg | grep nohello | tail -n 20`
	);
	await refreshConfig();
	showToast("Module reloaded");
}

$("#addPathBtn").addEventListener("click", () => {
	const row = document.createElement("div");
	row.className = "pathRow";
	const input = document.createElement("input");
	input.type = "text";
	input.placeholder = "/system/app/example";
	const remove = document.createElement("button");
	remove.type = "button";
	remove.textContent = "Del";
	remove.addEventListener("click", () => row.remove());
	row.append(input, remove);
	pathList.append(row);
	input.focus();
});

$("#loadAppsBtn").addEventListener("click", () => loadApps().catch((error) => showToast(error.message)));
$("#refreshBtn").addEventListener("click", () => refreshConfig().catch((error) => showToast(error.message)));
$("#searchInput").addEventListener("input", renderApps);
$("#saveBtn").addEventListener("click", () => saveConfig().catch((error) => showToast(error.message)));
$("#reloadBtn").addEventListener("click", () => reloadModule().catch((error) => {
	statusText.textContent = "Reload failed";
	showToast(error.message);
}));

for (const radio of document.querySelectorAll('input[name="scope"]')) {
	radio.addEventListener("change", () => {
		if (radio.value === "deny" && radio.checked && apps.length === 0) {
			loadApps().catch(() => {});
		}
	});
}

await refreshConfig().catch((error) => {
	statusText.textContent = "Read failed";
	showToast(error.message);
});

