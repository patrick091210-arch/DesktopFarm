// DesktopHarvest Official Site — Interactive Finder Simulator & GitHub Release Live Fetcher
(function () {
  const OWNER = "patrick091210-arch";
  const REPO = "DesktopFarm";
  const RELEASE_API = `https://api.github.com/repos/${OWNER}/${REPO}/releases/latest`;
  const REPO_API = `https://api.github.com/repos/${OWNER}/${REPO}`;

  let menuCoins = 120;
  let machineTimer = null;

  function updateMenuCoins(delta) {
    menuCoins += delta;
    const el = document.getElementById("sim-menu-coins");
    if (el) {
      el.textContent = `🌾 ${menuCoins}`;
    }
  }

  function setSimLog(message) {
    const logEl = document.getElementById("sim-console-log");
    if (logEl) {
      logEl.textContent = message;
    }
  }

  // 1. [💧 拖水壶浇水] Micro-Interaction
  window.triggerWateringDemo = function () {
    const card = document.getElementById("card-crop");
    const hud = document.getElementById("crop-hud");
    const emoji = document.getElementById("crop-emoji");
    const name = document.getElementById("crop-name");
    const meta = document.getElementById("crop-meta");
    const bar = document.getElementById("crop-progress");

    if (!card) return;
    card.classList.remove("pulse-water");
    void card.offsetWidth;
    card.classList.add("pulse-water");

    hud.className = "hud-pill";
    hud.textContent = "💧 水分 88% · 加速生长中";
    emoji.textContent = "🌿";
    name.textContent = "Wheat_01.crop";
    meta.textContent = "Moisture > 15 · 生长进度 72%";
    bar.style.width = "72%";
    setSimLog("[BotanyEngine] 💧水壶.tool 已浇灌 Wheat_01.crop (+50 水分)，IconWriter 正在原地写入 com.apple.ResourceFork...");

    setTimeout(() => {
      hud.className = "hud-pill ready";
      hud.textContent = "✨ 已成熟 · 转化为 .item";
      emoji.textContent = "🌾";
      name.textContent = "🌾小麦 ★.item";
      meta.textContent = "银星品质 (1.25×) · 价值 5 金币";
      bar.style.width = "100%";
      updateMenuCoins(5);
      setSimLog("[FSEvents] 🌾 Wheat_01.crop 成熟收获！原文件已安全转化为签名产物「🌾小麦 ★.item」(+5 金币, +3 XP)。");
    }, 950);
  };

  // 2. [📋 复制文件防作弊测试 (Cmd+D)] Micro-Interaction
  window.triggerCloneDemo = function () {
    const card = document.getElementById("card-apple");
    const hud = document.getElementById("apple-hud");
    const emoji = document.getElementById("apple-emoji");
    const name = document.getElementById("apple-name");
    const meta = document.getElementById("apple-meta");
    const bar = document.getElementById("apple-progress");

    if (!card) return;
    card.classList.remove("pulse-wither");
    void card.offsetWidth;
    card.classList.add("pulse-wither");

    hud.className = "hud-pill danger";
    hud.textContent = "⚠️ 检测到克隆 Inode · 价值 0";
    emoji.textContent = "🥀";
    name.textContent = "🥀枯萎的克隆果.item";
    meta.textContent = "同 UUID 异 st_ino · 已原地降级";
    bar.style.width = "100%";
    bar.style.background = "#ff453a";
    setSimLog("[AntiCheat] 🛡️ 拦截 Finder 复制操作 (Cmd+D)！UUID 相同但 POSIX st_ino 改变，文件已降级为「🥀枯萎的克隆果.item」(价值 0)。");

    setTimeout(() => {
      hud.className = "hud-pill ready";
      hud.textContent = "🔒 HMAC-SHA256 真品";
      emoji.textContent = "🍎";
      name.textContent = "🍎苹果.item";
      meta.textContent = "inode #849201 · 价值 8 金币";
      bar.style.background = "linear-gradient(90deg, #0a84ff, #34c759)";
    }, 3600);
  };

  // 3. [⚙️ 文件夹机器加工] Micro-Interaction
  window.triggerMachineDemo = function () {
    const card = document.getElementById("card-machine");
    const hud = document.getElementById("machine-hud");
    const emoji = document.getElementById("machine-emoji");
    const name = document.getElementById("machine-name");
    const meta = document.getElementById("machine-meta");
    const bar = document.getElementById("machine-progress");

    if (!card) return;
    if (machineTimer) clearInterval(machineTimer);

    card.classList.add("pulse-machine");
    emoji.textContent = "⚙️";
    emoji.classList.add("spin");
    name.textContent = "⚙️果酱加工机/";
    hud.className = "hud-pill warn";

    let progress = 20;
    bar.style.width = `${progress}%`;
    hud.textContent = "⚙️ .processing/ 锁定中 · 20%";
    meta.textContent = "配方: 2×🍎 → 🫙苹果酱 (20s)";
    setSimLog("[FolderMachine] ⚙️ 2×🍎苹果.item 已移入「⚙️果酱加工机/.processing/」隐藏锁目录，文件夹齿轮图标每秒重绘中...");

    machineTimer = setInterval(() => {
      progress += 20;
      bar.style.width = `${progress}%`;
      hud.textContent = `⚙️ 齿轮重绘中 · ${progress}%`;
      if (progress >= 100) {
        clearInterval(machineTimer);
        machineTimer = null;
        emoji.classList.remove("spin");
        emoji.textContent = "🫙";
        hud.className = "hud-pill ready";
        hud.textContent = "✨ 待收取 · +10 XP";
        name.textContent = "🫙苹果酱.item";
        meta.textContent = "加工完成 · 售价 36 金币";
        updateMenuCoins(36);
        setSimLog("[FolderMachine] ✨ 加工完成！已生成带 HMAC 签名的「🫙苹果酱.item」(售价 36 金币, +10 XP)。");
      }
    }, 320);
  };

  // 4. Desktop Pet Interactive State Cycling
  const PET_STATES = [
    { state: "Wander", bubble: "🐾 散步巡逻中" },
    { state: "Hungry", bubble: "🌾 饥饿 (饱食<35)" },
    { state: "SeekFood", bubble: "🥣 前往动物食槽" },
    { state: "Eat", bubble: "😋 进食小麦 (+45)" },
    { state: "Happy", bubble: "❤️ 心情愉悦 (+好感)" },
    { state: "Sleep", bubble: "💤 吃饱小憩 (25s)" },
    { state: "Idle", bubble: "✨ 准备产蛋/产奶" }
  ];
  let petStep = 0;

  window.cyclePetState = function (petEl, petTitle) {
    petStep = (petStep + 1) % PET_STATES.length;
    const item = PET_STATES[petStep];
    const span = petEl.querySelector(".pet-bubble");
    if (span) {
      span.textContent = `${item.state} · ${item.bubble}`;
    }
    updateMenuCoins(2);
    setSimLog(`[PetDirector] 抚摸了桌宠「${petTitle}」(+1.5 好感度)，AI 状态机切换至 -> ${item.state} (${item.bubble})`);
  };

  // 5. One-click terminal command copy
  window.copyTerminalCmd = function (cmdText, btnEl) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(cmdText).then(() => {
        const orig = btnEl.textContent;
        btnEl.textContent = "✓ 已复制";
        setTimeout(() => { btnEl.textContent = orig; }, 1800);
      });
    }
  };

  // 6. Live GitHub Release & Star count fetcher with fallback
  async function loadGitHubReleaseMeta() {
    try {
      const [relRes, repoRes] = await Promise.all([
        fetch(RELEASE_API, { headers: { Accept: "application/vnd.github+json" } }),
        fetch(REPO_API, { headers: { Accept: "application/vnd.github+json" } })
      ]);

      if (repoRes.ok) {
        const repoData = await repoRes.json();
        const starEl = document.getElementById("gh-star-count");
        if (starEl && typeof repoData.stargazers_count === "number") {
          starEl.textContent = `★ ${repoData.stargazers_count}`;
        }
      }

      if (relRes.ok) {
        const rel = await relRes.json();
        const verEl = document.getElementById("live-version");
        const sizeEl = document.getElementById("live-size");
        const dlEl = document.getElementById("live-downloads");

        if (verEl && rel.tag_name) {
          verEl.textContent = `最新版本 ${rel.tag_name}`;
        }

        if (Array.isArray(rel.assets) && rel.assets.length > 0) {
          const dmgAsset =
            rel.assets.find((a) => a.name === "DesktopHarvest.dmg") ||
            rel.assets.find((a) => a.name.endsWith(".dmg")) ||
            rel.assets[0];

          const totalDownloads = rel.assets.reduce((acc, a) => acc + (a.download_count || 0), 0);
          if (sizeEl && dmgAsset && dmgAsset.size) {
            const mb = (dmgAsset.size / (1024 * 1024)).toFixed(1);
            sizeEl.textContent = `${mb} MB Universal DMG`;
          }
          if (dlEl) {
            dlEl.textContent = `累计下载 ${totalDownloads} 次`;
          }
        }
      }
    } catch (_) {
      // Graceful fallback keeps static v1.0.0 metadata visible
    }
  }

  document.addEventListener("DOMContentLoaded", loadGitHubReleaseMeta);
})();
