import { exec, fullScreen, moduleInfo, spawn, toast } from "./kernelsu.js";

const state = {
  partitions: [],
  running: false,
};

const els = {
  bynameDir: document.getElementById("byname-dir"),
  moduleInfo: document.getElementById("module-info"),
  partitionTableBody: document.getElementById("partition-table-body"),
  sourceSelect: document.getElementById("source-select"),
  targetSelect: document.getElementById("target-select"),
  outputDir: document.getElementById("output-dir"),
  flashToggle: document.getElementById("flash-toggle"),
  refreshBtn: document.getElementById("refresh-btn"),
  patchForm: document.getElementById("patch-form"),
  patchBtn: document.getElementById("patch-btn"),
  logView: document.getElementById("log-view"),
  resultCard: document.getElementById("result-card"),
};

function shellEscape(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

function formatBytes(bytes) {
  const num = Number(bytes) || 0;
  const units = ["B", "KB", "MB", "GB"];
  let value = num;
  let index = 0;

  while (value >= 1024 && index < units.length - 1) {
    value /= 1024;
    index += 1;
  }

  return `${value.toFixed(value >= 10 || index === 0 ? 0 : 1)} ${units[index]}`;
}

function appendLog(message = "") {
  els.logView.textContent += `${message}\n`;
  els.logView.scrollTop = els.logView.scrollHeight;
}

function setLog(message) {
  els.logView.textContent = `${message}\n`;
}

function avbLabel(kind) {
  if (kind === "footer") {
    return '<span class="pill pill-footer">Footer</span>';
  }
  if (kind === "header") {
    return '<span class="pill pill-header">Header</span>';
  }
  return '<span class="pill pill-none">None</span>';
}

function setRunning(running) {
  state.running = running;
  els.patchBtn.disabled = running;
  els.refreshBtn.disabled = running;
}

function renderPartitions() {
  if (!state.partitions.length) {
    els.partitionTableBody.innerHTML = '<tr><td colspan="4" class="empty">没有找到可用分区</td></tr>';
    return;
  }

  els.partitionTableBody.innerHTML = state.partitions
    .map((item) => `
      <tr>
        <td>${item.name}</td>
        <td>${avbLabel(item.kind)}</td>
        <td>${formatBytes(item.size)}</td>
        <td>${item.vbmetaSize > 0 ? formatBytes(item.vbmetaSize) : "-"}</td>
      </tr>
    `)
    .join("");
}

function fillSelect(select, partitions, preferredNames = []) {
  const options = partitions
    .map((item) => `<option value="${item.name}">${item.name} · ${item.kind} · ${formatBytes(item.size)}</option>`)
    .join("");

  select.innerHTML = options;

  const preferred = preferredNames.find((name) => partitions.some((item) => item.name === name));
  if (preferred) {
    select.value = preferred;
  } else if (partitions[0]) {
    select.value = partitions[0].name;
  }
}

function renderSelects() {
  const sources = state.partitions.filter((item) => item.kind === "footer" || item.kind === "header");
  const targets = state.partitions.filter((item) => item.size > 64);

  fillSelect(els.sourceSelect, sources, ["vbmeta_a", "vbmeta", "vbmeta_b", "boot_a", "init_boot_a"]);
  fillSelect(els.targetSelect, targets, ["boot_a", "init_boot_a", "boot", "init_boot", "vendor_boot_a"]);
}

function parseList(stdout) {
  const partitions = [];
  let bynameDir = "";

  stdout
    .trim()
    .split("\n")
    .filter(Boolean)
    .forEach((line) => {
      const parts = line.split("|");
      if (parts[0] === "META" && parts[1] === "byname") {
        bynameDir = parts[2] || "";
        return;
      }

      if (parts[0] !== "PART") {
        return;
      }

      const [_, name, path, kind, size, origSize, vbmetaOffset, vbmetaSize] = parts;
      partitions.push({
        name,
        path,
        kind,
        size: Number(size),
        origSize: Number(origSize),
        vbmetaOffset: Number(vbmetaOffset),
        vbmetaSize: Number(vbmetaSize),
      });
    });

  partitions.sort((a, b) => a.name.localeCompare(b.name));
  state.partitions = partitions;
  els.bynameDir.textContent = bynameDir || "未检测到";
  renderPartitions();
  renderSelects();
}

async function refreshPartitions() {
  setLog("正在扫描手机分区...");
  els.resultCard.classList.add("hidden");

  try {
    const result = await exec("sh /data/adb/modules/vbpatch/scripts/backend.sh list");
    if (result.errno !== 0) {
      throw new Error(result.stderr || result.stdout || "扫描失败");
    }
    parseList(result.stdout);
    setLog("扫描完成，可以开始选择源分区和目标分区。");
  } catch (error) {
    state.partitions = [];
    renderPartitions();
    els.bynameDir.textContent = "扫描失败";
    setLog(`扫描失败：${error.message}`);
    toast("分区扫描失败");
  }
}

function parsePatchResult(output) {
  const data = {};
  output
    .split("\n")
    .filter((line) => line.startsWith("RESULT|"))
    .forEach((line) => {
      const [, key, value] = line.split("|");
      data[key] = value;
    });
  return data;
}

function showResultCard(result) {
  const lines = ['<strong>结果摘要</strong>'];
  if (result.output) {
    lines.push(`<p>输出镜像：${result.output}</p>`);
  }
  if (result.backup) {
    lines.push(`<p>目标分区备份：${result.backup}</p>`);
  }
  lines.push(`<p>是否已回写：${result.flashed === "1" ? "是" : "否"}</p>`);
  els.resultCard.innerHTML = lines.join("");
  els.resultCard.classList.remove("hidden");
}

function runPatch(command) {
  return new Promise((resolve, reject) => {
    const child = spawn("sh", ["-c", command]);
    let stdout = "";
    let stderr = "";

    child.stdout.on("data", (chunk) => {
      stdout += chunk;
      appendLog(chunk.replace(/\n$/, ""));
    });

    child.stderr.on("data", (chunk) => {
      stderr += chunk;
      appendLog(chunk.replace(/\n$/, ""));
    });

    child.on("exit", (code) => {
      if (code === 0) {
        resolve({ stdout, stderr });
      } else {
        reject(new Error(stderr || stdout || `命令退出码 ${code}`));
      }
    });

    child.on("error", (error) => {
      reject(error);
    });
  });
}

async function handlePatchSubmit(event) {
  event.preventDefault();
  if (state.running) {
    return;
  }

  const source = els.sourceSelect.value;
  const target = els.targetSelect.value;
  const outputDir = els.outputDir.value.trim() || "/sdcard/Download/vbpatch";
  const flashBack = els.flashToggle.checked ? "1" : "0";

  if (!source || !target) {
    toast("请先选择源分区和目标分区");
    return;
  }

  if (source === target) {
    toast("源分区和目标分区不能相同");
    return;
  }

  if (els.flashToggle.checked) {
    const confirmed = window.confirm("即将直接回写真实分区，继续吗？");
    if (!confirmed) {
      return;
    }
  }

  setRunning(true);
  els.resultCard.classList.add("hidden");
  setLog("开始执行修补...\n");

  const command = [
    "sh",
    "/data/adb/modules/vbpatch/scripts/backend.sh",
    "patch",
    shellEscape(source),
    shellEscape(target),
    shellEscape(outputDir),
    flashBack,
  ].join(" ");

  try {
    const { stdout } = await runPatch(command);
    const result = parsePatchResult(stdout);
    showResultCard(result);
    toast(result.flashed === "1" ? "修补并回写完成" : "修补完成");
  } catch (error) {
    appendLog(`\n失败：${error.message}`);
    toast("修补失败");
  } finally {
    setRunning(false);
  }
}

function init() {
  fullScreen(true);
  try {
    els.moduleInfo.textContent = moduleInfo() || "vbpatch";
  } catch (error) {
    els.moduleInfo.textContent = "vbpatch";
  }

  els.refreshBtn.addEventListener("click", refreshPartitions);
  els.patchForm.addEventListener("submit", handlePatchSubmit);

  const savedOutputDir = localStorage.getItem("vbpatch.outputDir");
  const savedFlash = localStorage.getItem("vbpatch.flashBack");
  if (savedOutputDir) {
    els.outputDir.value = savedOutputDir;
  }
  if (savedFlash === "1") {
    els.flashToggle.checked = true;
  }

  els.outputDir.addEventListener("change", () => {
    localStorage.setItem("vbpatch.outputDir", els.outputDir.value.trim());
  });

  els.flashToggle.addEventListener("change", () => {
    localStorage.setItem("vbpatch.flashBack", els.flashToggle.checked ? "1" : "0");
  });

  refreshPartitions();
}

init();
