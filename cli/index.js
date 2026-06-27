#!/usr/bin/env node

const qrcode = require('qrcode-terminal');
const chalk = require('chalk');
const WebSocket = require('ws');
const { spawn } = require('child_process');
const readline = require('readline');
const fs = require('fs');
const path = require('path');
const os = require('os');
const net = require('net');
const crypto = require('crypto');

const authToken = crypto.randomBytes(16).toString('hex');

const VM_URL_TIMEOUT_MS = 300000; // 5 minutes (initial gradle builds take time)
const SERVICE_URI_KEYS = [
  'vmServiceUri',
  'observatoryUri',
  'debugServiceUri',
  'debuggerUri',
  'debugWsUri',
  'wsUri',
];

const activeProxies = new Set();

function parseArgs(argv) {
  let deviceId = null;
  let qrOnly = false;
  let jsonOutput = false;
  const passthrough = [];

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];

    if (arg === '--device' || arg === '-d') {
      const next = argv[i + 1];
      if (!next || next.startsWith('-')) {
        throw new Error('Missing value for --device.');
      }
      deviceId = next;
      i += 1;
      continue;
    }

    if (arg.startsWith('--device=')) {
      const value = arg.split('=').slice(1).join('=');
      if (!value) {
        throw new Error('Missing value for --device.');
      }
      deviceId = value;
      continue;
    }

    if (arg === '--qr-only') {
      qrOnly = true;
      continue;
    }

    if (arg === '--json') {
      jsonOutput = true;
      continue;
    }

    passthrough.push(arg);
  }

  return { deviceId, qrOnly, jsonOutput, passthrough };
}

function parseMachineLine(line) {
  const trimmed = line.trim();
  if (!trimmed) {
    return null;
  }

  if (!(trimmed.startsWith('{') || trimmed.startsWith('['))) {
    return null;
  }

  try {
    return JSON.parse(trimmed);
  } catch (_) {
    return null;
  }
}

function isValidUri(value) {
  return typeof value === 'string' && /^(ws|http)s?:\/\//.test(value);
}

function findUriByKeys(obj, keys) {
  if (!obj || typeof obj !== 'object') {
    return null;
  }

  for (const key of keys) {
    if (isValidUri(obj[key])) {
      return obj[key];
    }
  }

  return null;
}

function findAnyUri(obj) {
  if (!obj || typeof obj !== 'object') {
    return null;
  }

  for (const [key, value] of Object.entries(obj)) {
    if (/uri/i.test(key) && isValidUri(value)) {
      return value;
    }
  }

  return null;
}

function extractVmServiceUri(event) {
  if (!event || typeof event !== 'object') {
    return null;
  }

  const params = event.params || event;
  let uri = findUriByKeys(params, SERVICE_URI_KEYS);
  if (uri) {
    return uri;
  }

  const debuggingOptions = params.debuggingOptions || params.debugOptions;
  uri = findUriByKeys(debuggingOptions, SERVICE_URI_KEYS);
  if (uri) {
    return uri;
  }

  return findAnyUri(params);
}

function isLoopbackHost(hostname) {
  return hostname === 'localhost' || hostname === '127.0.0.1' || hostname === '::1' || hostname === '0.0.0.0';
}

function scoreLanIp(ip) {
  if (ip.startsWith('192.168.')) {
    return 3;
  }
  if (ip.startsWith('10.')) {
    return 2;
  }
  if (/^172\.(1[6-9]|2\d|3[0-1])\./.test(ip)) {
    return 1;
  }
  return 0;
}

function getLanIp() {
  const interfaces = os.networkInterfaces();
  const candidates = [];

  for (const entries of Object.values(interfaces)) {
    for (const net of entries || []) {
      if (net.family !== 'IPv4' || net.internal) {
        continue;
      }
      candidates.push(net.address);
    }
  }

  if (candidates.length === 0) {
    return null;
  }

  candidates.sort((a, b) => scoreLanIp(b) - scoreLanIp(a));
  return candidates[0];
}

function getDefaultPort(protocol) {
  if (protocol === 'wss:' || protocol === 'https:') {
    return 443;
  }
  if (protocol === 'ws:' || protocol === 'http:') {
    return 80;
  }
  return null;
}

function registerProxy(server) {
  activeProxies.add(server);
  server.on('close', () => activeProxies.delete(server));
}

function closeAllProxies() {
  for (const server of activeProxies) {
    try {
      server.close();
    } catch (_) {
      // Ignore errors while shutting down.
    }
  }
  activeProxies.clear();
}

process.on('exit', closeAllProxies);

// ---------------------------------------------------------------------------
// Control Server — lets CLI push events (new VM URL, flutter stopped) to apps
// ---------------------------------------------------------------------------
function startControlServer() {
  return new Promise((resolve, reject) => {
    const wss = new WebSocket.Server({ 
      port: 0, 
      host: '0.0.0.0',
      verifyClient: (info, cb) => {
        try {
          const url = new URL(info.req.url, `http://${info.req.headers.host}`);
          if (url.searchParams.get('token') === authToken) {
            cb(true);
          } else {
            cb(false, 401, 'Unauthorized');
          }
        } catch (e) {
          cb(false, 400, 'Bad Request');
        }
      }
    });

    wss.on('connection', (ws, req) => {
      ws.on('message', (data) => {
        try {
          const msg = JSON.parse(data.toString());
          wss.emit('client_message', msg);
        } catch (_) {}
      });
    });

    wss.on('listening', () => {
      const port = wss.address().port;

      // Broadcast helper — sends a JSON message to every connected app client
      wss.broadcast = (msg) => {
        const payload = JSON.stringify(msg);
        wss.clients.forEach((client) => {
          if (client.readyState === WebSocket.OPEN) {
            client.send(payload);
          }
        });
      };

      registerProxy(wss);
      resolve({ wss, port });
    });

    wss.on('error', reject);
  });
}

// ---------------------------------------------------------------------------
// Screenshot / Live Preview Server
// ---------------------------------------------------------------------------
function startScreenshotServer(deviceId) {
  return new Promise((resolve, reject) => {
    try {
      const wss = new WebSocket.Server({ 
        port: 0, 
        host: '0.0.0.0',
        verifyClient: (info, cb) => {
          try {
            const url = new URL(info.req.url, `http://${info.req.headers.host}`);
            if (url.searchParams.get('token') === authToken) {
              cb(true);
            } else {
              cb(false, 401, 'Unauthorized');
            }
          } catch (e) {
            cb(false, 400, 'Bad Request');
          }
        }
      });
      let intervalId = null;
      let connections = 0;

      wss.on('listening', () => {
        const port = wss.address().port;
        resolve(port);
      });

      wss.on('error', (err) => {
        reject(err);
      });

      wss.on('connection', (ws) => {
        connections++;
        
        if (connections === 1) {
          intervalId = setInterval(() => {
            const adbArgs = deviceId ? ['-s', deviceId, 'exec-out', 'screencap', '-p'] : ['exec-out', 'screencap', '-p'];
            const child = spawn('adb', adbArgs);
            const chunks = [];
            
            child.stdout.on('data', chunk => chunks.push(chunk));
            child.on('close', code => {
              if (code === 0 && wss.clients.size > 0) {
                const buffer = Buffer.concat(chunks);
                wss.clients.forEach(client => {
                  if (client.readyState === WebSocket.OPEN) {
                    client.send(buffer);
                  }
                });
              }
            });
          }, 500); // 2 fps polling
        }

        ws.on('close', () => {
          connections--;
          if (connections === 0 && intervalId) {
            clearInterval(intervalId);
            intervalId = null;
          }
        });
      });

      registerProxy(wss);
    } catch(err) {
      reject(err);
    }
  });
}

function startTcpProxy(targetHost, targetPort) {
  return new Promise((resolve, reject) => {
    const server = net.createServer((client) => {
      const upstream = net.connect({ host: targetHost, port: targetPort });

      const closeBoth = () => {
        client.destroy();
        upstream.destroy();
      };

      client.on('error', closeBoth);
      upstream.on('error', closeBoth);

      client.pipe(upstream);
      upstream.pipe(client);
    });

    server.on('error', reject);

    server.listen(0, '0.0.0.0', () => {
      registerProxy(server);
      const address = server.address();
      resolve({ server, port: address.port });
    });
  });
}

async function prepareVmServiceUrl(originalUrl) {
  let parsed;
  try {
    parsed = new URL(originalUrl);
  } catch (_) {
    return { url: originalUrl, originalUrl, replaced: false, proxied: false };
  }

  if (!isLoopbackHost(parsed.hostname)) {
    return { url: originalUrl, originalUrl, replaced: false, proxied: false };
  }

  const lanIp = getLanIp();
  if (!lanIp) {
    console.warn(chalk.yellow('\n⚠️  Warning: Could not detect LAN IP address.'));
    console.warn(chalk.yellow('Make sure your PC and phone are on the same WiFi network.'));
    console.warn(chalk.yellow('Connection may fail with localhost URL.\n'));
    return { url: originalUrl, originalUrl, replaced: false, proxied: false };
  }

  const port = parsed.port ? Number(parsed.port) : getDefaultPort(parsed.protocol);
  if (!port) {
    return { url: originalUrl, originalUrl, replaced: false, proxied: false };
  }

  const targetHost = parsed.hostname === '0.0.0.0' ? '127.0.0.1' : parsed.hostname;
  try {
    const proxy = await startTcpProxy(targetHost, port);
    parsed.hostname = lanIp;
    parsed.port = String(proxy.port);
    return {
      url: parsed.toString(),
      originalUrl,
      replaced: true,
      proxied: true,
      proxyHost: lanIp,
      proxyPort: proxy.port,
    };
  } catch (err) {
    console.warn(chalk.yellow(`\n⚠️  Warning: Failed to start LAN proxy (${err.message}).`));
    parsed.hostname = lanIp;
    return { url: parsed.toString(), originalUrl, replaced: true, proxied: false };
  }
}

function assertFlutterProject(cwd) {
  const pubspecPath = path.join(cwd, 'pubspec.yaml');
  if (!fs.existsSync(pubspecPath)) {
    throw new Error('No pubspec.yaml file found. Run this command from the root of your Flutter project.');
  }
}

function runFlutterDevices() {
  return new Promise((resolve, reject) => {
    const child = spawn('flutter', ['devices', '--machine'], { stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';

    child.stdout.on('data', (data) => {
      stdout += data.toString();
    });

    child.stderr.on('data', (data) => {
      stderr += data.toString();
    });

    child.on('error', (err) => {
      reject(err);
    });

    child.on('close', (code) => {
      if (code !== 0) {
        reject(new Error(stderr || `flutter devices exited with code ${code}`));
        return;
      }

      try {
        const devices = JSON.parse(stdout.trim());
        if (!Array.isArray(devices)) {
          reject(new Error('Unexpected output from flutter devices.'));
          return;
        }
        resolve(devices);
      } catch (err) {
        reject(err);
      }
    });
  });
}

function formatDevice(device) {
  const platform = device.platform || device.platformType || 'unknown';
  return `${device.name} (${platform}) - id: ${device.id}`;
}

async function promptForDevice(devices) {
  if (!process.stdin.isTTY) {
    throw new Error('Multiple devices detected. Use --device <id> to select one.');
  }

  console.log(chalk.yellow('\nAvailable devices:'));
  devices.forEach((device, index) => {
    console.log(`  ${index + 1}) ${formatDevice(device)}`);
  });

  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });

  const answer = await new Promise((resolve) => {
    rl.question(chalk.cyan('\nSelect a device by number or id: '), resolve);
  });

  rl.close();

  const trimmed = answer.trim();
  if (!trimmed) {
    throw new Error('No device selected.');
  }

  const asIndex = Number(trimmed);
  if (Number.isInteger(asIndex) && asIndex >= 1 && asIndex <= devices.length) {
    return devices[asIndex - 1].id;
  }

  const match = devices.find((device) => device.id === trimmed);
  if (match) {
    return match.id;
  }

  throw new Error(`Unknown device selection: ${trimmed}`);
}

async function resolveDeviceId(deviceIdArg, options = {}) {
  if (deviceIdArg) {
    return deviceIdArg;
  }

  let devices = [];
  try {
    devices = await runFlutterDevices();
  } catch (err) {
    if (err.code === 'ENOENT') {
      throw new Error('Flutter was not found on your PATH. Install Flutter and try again.');
    }
    throw err;
  }
  const supported = devices.filter((device) => device.isSupported !== false);

  if (supported.length === 0) {
    const offline = devices.filter((d) => !d.isSupported && (d.emulator === false || d.emulator === undefined));
    if (offline.length > 0) {
      const hints = offline.map((d) => `  - ${d.name} (${d.id})`).join('\n');
      throw new Error(`No available devices. Found offline/unauthorized devices:\n${hints}\n\nTry:\n  - Enable USB debugging on your device\n  - Run 'adb devices' and authorize the device\n  - Reconnect your device`);
    }
    throw new Error('No devices found. Connect a device or start an emulator.');
  }

  if (supported.length === 1) {
    if (!options.quiet) {
      console.log(chalk.gray(`Using device: ${formatDevice(supported[0])}`));
    }
    return supported[0].id;
  }

  if (options.jsonOutput) {
    throw new Error('Multiple devices detected. Use --device <id> with --json.');
  }

  return promptForDevice(supported);
}

function handleFlutterError(err) {
  if (err.code === 'ENOENT') {
    console.error(chalk.red('Flutter was not found on your PATH. Install Flutter and try again.'));
  } else {
    console.error(chalk.red(`Failed to start Flutter: ${err.message}`));
  }

  process.exitCode = 1;
}

function hasWebHostnameFlag(args) {
  return args.some((arg) => arg === '--web-hostname' || arg.startsWith('--web-hostname='));
}

async function main() {
  let options = null;
  try {
    options = parseArgs(process.argv.slice(2));
  } catch (err) {
    console.error(chalk.red(err.message));
    process.exitCode = 1;
    return;
  }

  const {
    deviceId: deviceIdArg,
    passthrough,
    qrOnly,
    jsonOutput,
  } = options;

  if (qrOnly && jsonOutput) {
    console.error(chalk.red('Use either --qr-only or --json, not both.'));
    process.exitCode = 1;
    return;
  }

  const quiet = qrOnly || jsonOutput;

  if (!quiet) {
    console.log(chalk.cyan.bold('\n🚀 FlutterBridge CLI'));
  }

  try {
    assertFlutterProject(process.cwd());
  } catch (err) {
    console.error(chalk.red(err.message));
    process.exitCode = 1;
    return;
  }

  let deviceId = null;
  try {
    deviceId = await resolveDeviceId(deviceIdArg, { quiet, jsonOutput });
  } catch (err) {
    console.error(chalk.red(`Device selection failed: ${err.message}`));
    process.exitCode = 1;
    return;
  }

  // Start control server for push notifications (hot restart URL, flutter stopped)
  let controlServer = null;
  let controlPort = null;
  try {
    controlServer = await startControlServer();
    controlPort = controlServer.port;
    if (!quiet) console.log(chalk.gray(`Control server on port ${controlPort}`));
  } catch (e) {
    if (!quiet) console.warn(chalk.yellow(`Warning: Failed to start control server: ${e.message}`));
  }

  let previewPort = null;
  try {
    previewPort = await startScreenshotServer(deviceId);
    if (!quiet) console.log(chalk.gray(`Started Live Preview server on port ${previewPort}`));
  } catch (e) {
    if (!quiet) console.warn(chalk.yellow(`Warning: Failed to start Live Preview server: ${e.message}`));
  }

  if (!quiet) {
    console.log(chalk.gray('Starting Flutter...\n'));
  }

  const flutterArgs = ['run', '--machine'];
  if (deviceId) {
    flutterArgs.push('-d', deviceId);
  }
  if (deviceId === 'chrome' && !hasWebHostnameFlag(passthrough)) {
    flutterArgs.push('--web-hostname', '0.0.0.0');
  }
  if (passthrough.length > 0) {
    flutterArgs.push(...passthrough);
  }

  const flutter = spawn('flutter', flutterArgs, { stdio: ['pipe', 'pipe', 'pipe'] });
  let stdoutBuffer = '';
  let stderrBuffer = '';
  let vmServiceUrl = null;   // The current active VM URL (updated on each hot restart)
  let publishPending = false;

  const handleClientMessage = (msg) => {
    if (msg.type === 'hot_reload') {
      flutter.stdin.write('r');
    } else if (msg.type === 'hot_restart') {
      flutter.stdin.write('R');
    }
  };
  if (controlServer) {
    controlServer.wss.on('client_message', handleClientMessage);
  }

  const vmTimeout = setTimeout(() => {
    if (!vmServiceUrl) {
      console.error(chalk.red(`Timed out after ${VM_URL_TIMEOUT_MS / 1000}s waiting for VM service URL.`));
      flutter.kill('SIGINT');
      process.exitCode = 1;
    }
  }, VM_URL_TIMEOUT_MS);

  flutter.on('error', handleFlutterError);

  // Build the final QR URL by appending previewPort and controlPort as query params
  function buildFinalUrl(vmUrl) {
    if (!previewPort && !controlPort) return vmUrl;
    try {
      const u = new URL(vmUrl);
      if (previewPort) u.searchParams.set('previewPort', previewPort);
      if (controlPort) u.searchParams.set('controlPort', controlPort);
      u.searchParams.set('token', authToken);
      return u.toString();
    } catch (_) {
      return vmUrl;
    }
  }

  // Called the first time a VM URL is found — prints QR and sets up the session
  function publishUrl(result) {
    const finalUrl = buildFinalUrl(result.url);
    vmServiceUrl = finalUrl;
    clearTimeout(vmTimeout);

    if (jsonOutput) {
      const payload = { vmServiceUri: vmServiceUrl, deviceId };
      if (result.replaced) {
        payload.originalVmServiceUri = result.originalUrl;
      }
      if (result.proxied) {
        payload.proxy = { host: result.proxyHost, port: result.proxyPort };
      }
      console.log(JSON.stringify(payload));
      return;
    }

    if (!qrOnly) {
      console.log(chalk.yellow('\nScan this QR with FlutterBridge app:\n'));
    }
    qrcode.generate(finalUrl, { small: true });
    if (!qrOnly) {
      if (result.proxied) {
        console.log(chalk.gray(`LAN proxy running at ws://${result.proxyHost}:${result.proxyPort}`));
        console.log(chalk.gray(`Proxy target: ${result.originalUrl}`));
      } else if (result.replaced) {
        console.log(chalk.gray(`Rewrote VM URL for LAN access: ${finalUrl}`));
        console.log(chalk.gray(`Original VM URL: ${result.originalUrl}`));
      }
      console.log(chalk.green(`\nVM URL: ${finalUrl}`));
    }
  }

  // Called on subsequent hot restarts — broadcasts new URL to all connected apps
  function updateUrl(result) {
    const finalUrl = buildFinalUrl(result.url);
    vmServiceUrl = finalUrl;

    if (!quiet) {
      console.log(chalk.cyan('\n🔄 Hot restart detected — broadcasting new VM URL to companion apps...'));
      console.log(chalk.gray(`New VM URL: ${finalUrl}`));
    }

    if (controlServer) {
      controlServer.wss.broadcast({ type: 'vm_url_changed', url: finalUrl });
    }
  }

  const handleMachineChunk = (buffer, data) => {
    let nextBuffer = buffer + data.toString();
    const lines = nextBuffer.split(/\r?\n/);
    nextBuffer = lines.pop();

    for (const line of lines) {
      const json = parseMachineLine(line);
      if (!json) {
        continue;
      }

      const events = Array.isArray(json) ? json : [json];
      for (const event of events) {
        const url = extractVmServiceUri(event);
        // Accept VM URLs on first connect AND on every subsequent hot restart.
        // publishPending prevents double-processing when two events fire quickly.
        // Dedup: Chrome emits a secondary DevTools http:// URL immediately after
        // the ws:// URL. Ignore it if the path (session token) hasn't changed.
        if (url && !publishPending) {
          let isSameSession = false;
          if (vmServiceUrl) {
            try {
              const currentPath = new URL(vmServiceUrl).pathname;
              const newPath = new URL(url).pathname;
              isSameSession = currentPath === newPath;
            } catch (_) {}
          }
          if (isSameSession) continue;

          const isFirstUrl = !vmServiceUrl;
          publishPending = true;

          prepareVmServiceUrl(url)
            .then((result) => {
              publishPending = false;
              if (isFirstUrl) {
                publishUrl(result);
              } else {
                updateUrl(result);
              }
            })
            .catch((err) => {
              publishPending = false;
              if (!quiet) {
                console.error(chalk.red(`Failed to prepare VM service URL: ${err.message}`));
              }
              const fallback = { url, originalUrl: url, replaced: false, proxied: false };
              if (isFirstUrl) {
                publishUrl(fallback);
              } else {
                updateUrl(fallback);
              }
            });
        }
      }
    }

    return nextBuffer;
  };

  flutter.stdout.on('data', (data) => {
    stdoutBuffer = handleMachineChunk(stdoutBuffer, data);
  });

  flutter.stderr.on('data', (data) => {
    stderrBuffer = handleMachineChunk(stderrBuffer, data);
    if (!quiet) {
      process.stdout.write(chalk.gray(data.toString()));
    }
  });

  flutter.on('close', (code) => {
    clearTimeout(vmTimeout);
    if (controlServer) {
      controlServer.wss.off('client_message', handleClientMessage);
    }

    // Notify all connected companion apps that Flutter has stopped
    if (controlServer) {
      controlServer.wss.broadcast({ type: 'flutter_stopped' });
    }

    if (code && code !== 0) {
      process.exitCode = code;
    }
  });
}

main().catch((err) => {
  console.error(chalk.red(`Unexpected error: ${err.message}`));
  process.exitCode = 1;
});