package com.kreyzi.app;

import android.Manifest;
import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.os.Handler;
import android.os.Looper;
import android.provider.OpenableColumns;
import android.text.Editable;
import android.text.TextWatcher;
import android.view.View;
import android.widget.*;
import androidx.appcompat.app.AppCompatActivity;
import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;
import androidx.core.content.FileProvider;

import com.google.android.material.button.MaterialButton;
import com.google.android.material.card.MaterialCardView;
import com.google.android.material.snackbar.Snackbar;

import java.io.*;
import java.text.SimpleDateFormat;
import java.util.*;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class MainActivity extends AppCompatActivity {

    // ── Views ────────────────────────────────────────────────────────────────
    private EditText  etInput, etOutput;
    private TextView  tvInputCount, tvOutputCount, tvLogs;
    private Spinner   spPreset;
    private RadioGroup rgLuaVersion;
    private RadioButton rbLuaU, rbLua51, rbDefault;
    private MaterialButton btnObfuscate, btnPaste, btnLoadFile, btnClearInput;
    private MaterialButton btnCopyOutput, btnSaveOutput, btnClearOutput;
    private MaterialCardView cardLogs, cardOutput;
    private ProgressBar progressBar;
    private ScrollView svLogs;

    // ── State ────────────────────────────────────────────────────────────────
    private static final int REQ_READ_STORAGE  = 101;
    private static final int REQ_WRITE_STORAGE = 102;
    private static final int REQ_OPEN_FILE     = 200;

    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private boolean running = false;

    // Config name → display label
    private final String[] PRESET_LABELS = {
            "Light  (Fast, basic protection)",
            "Medium  (Balanced)",
            "Hard  (Maximum security)",
            "Minimal  (Minify only)",
            "CustomBVM1  (Custom BVM config)"
    };
    private final String[] PRESET_IDS = {
            "roblox_light",
            "roblox_medium",
            "roblox_hard",
            "roblox_minimal",
            "roblox_custombvm1"
    };

    // ── Lifecycle ─────────────────────────────────────────────────────────────

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);

        bindViews();
        setupPresetSpinner();
        setupListeners();
        appendLog("✅ Kreyzi Obfuscator ready.");
        appendLog("📦 Lua assets will be extracted on first run.");
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        executor.shutdownNow();
    }

    // ── View binding ──────────────────────────────────────────────────────────

    private void bindViews() {
        etInput      = findViewById(R.id.etInput);
        etOutput     = findViewById(R.id.etOutput);
        tvInputCount = findViewById(R.id.tvInputCount);
        tvOutputCount= findViewById(R.id.tvOutputCount);
        tvLogs       = findViewById(R.id.tvLogs);
        spPreset     = findViewById(R.id.spPreset);
        rgLuaVersion = findViewById(R.id.rgLuaVersion);
        rbLuaU       = findViewById(R.id.rbLuaU);
        rbLua51      = findViewById(R.id.rbLua51);
        rbDefault    = findViewById(R.id.rbDefault);
        btnObfuscate = findViewById(R.id.btnObfuscate);
        btnPaste     = findViewById(R.id.btnPaste);
        btnLoadFile  = findViewById(R.id.btnLoadFile);
        btnClearInput= findViewById(R.id.btnClearInput);
        btnCopyOutput= findViewById(R.id.btnCopyOutput);
        btnSaveOutput= findViewById(R.id.btnSaveOutput);
        btnClearOutput=findViewById(R.id.btnClearOutput);
        cardLogs     = findViewById(R.id.cardLogs);
        cardOutput   = findViewById(R.id.cardOutput);
        progressBar  = findViewById(R.id.progressBar);
        svLogs       = findViewById(R.id.svLogs);
    }

    // ── Preset spinner ────────────────────────────────────────────────────────

    private void setupPresetSpinner() {
        ArrayAdapter<String> adapter = new ArrayAdapter<>(
                this,
                android.R.layout.simple_spinner_item,
                PRESET_LABELS
        );
        adapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item);
        spPreset.setAdapter(adapter);
    }

    // ── Listeners ─────────────────────────────────────────────────────────────

    private void setupListeners() {
        etInput.addTextChangedListener(new TextWatcher() {
            @Override public void beforeTextChanged(CharSequence s,int st,int c,int a){}
            @Override public void onTextChanged(CharSequence s,int st,int b,int c){}
            @Override public void afterTextChanged(Editable s) {
                int lines = s.toString().split("\n", -1).length;
                tvInputCount.setText(s.length() + " chars / " + lines + " lines");
            }
        });

        btnPaste.setOnClickListener(v -> {
            ClipboardManager cm = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
            if (cm != null && cm.hasPrimaryClip() && cm.getPrimaryClip() != null) {
                CharSequence text = cm.getPrimaryClip().getItemAt(0).coerceToText(this);
                etInput.setText(text);
                etInput.setSelection(etInput.getText().length());
                toast("Pasted " + text.length() + " characters");
            } else {
                toast("Clipboard is empty");
            }
        });

        btnLoadFile.setOnClickListener(v -> openFilePicker());

        btnClearInput.setOnClickListener(v -> {
            etInput.setText("");
            toast("Input cleared");
        });

        btnObfuscate.setOnClickListener(v -> {
            if (running) {
                toast("Already running, please wait…");
                return;
            }
            startObfuscation();
        });

        btnCopyOutput.setOnClickListener(v -> {
            String out = etOutput.getText().toString();
            if (out.isEmpty()) { toast("No output to copy"); return; }
            ClipboardManager cm = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
            if (cm != null) {
                cm.setPrimaryClip(ClipData.newPlainText("obfuscated", out));
                Snackbar.make(btnCopyOutput, "Copied " + out.length() + " chars ✓", Snackbar.LENGTH_SHORT).show();
            }
        });

        btnSaveOutput.setOnClickListener(v -> saveOutput());

        btnClearOutput.setOnClickListener(v -> {
            etOutput.setText("");
            tvOutputCount.setText("0 chars");
            tvLogs.setText("");
            toast("Output & logs cleared");
        });
    }

    // ── Obfuscation ───────────────────────────────────────────────────────────

    private void startObfuscation() {
        String source = etInput.getText().toString().trim();
        if (source.isEmpty()) {
            toast("Paste or load a Lua script first");
            return;
        }

        int presetIdx   = spPreset.getSelectedItemPosition();
        String presetId = PRESET_IDS[presetIdx];

        int radioId = rgLuaVersion.getCheckedRadioButtonId();
        String luaVer;
        if      (radioId == R.id.rbLuaU)   luaVer = "LuaU";
        else if (radioId == R.id.rbLua51)  luaVer = "Lua51";
        else                               luaVer = "";   // use config default

        // Reset UI
        etOutput.setText("");
        tvOutputCount.setText("0 chars");
        tvLogs.setText("");
        cardLogs.setVisibility(View.VISIBLE);
        cardOutput.setVisibility(View.VISIBLE);
        setRunning(true);

        appendLog("▶ Starting obfuscation…");
        appendLog("  Preset   : " + PRESET_LABELS[presetIdx].split(" ")[0]);
        appendLog("  Lua ver  : " + (luaVer.isEmpty() ? "config default" : luaVer));
        appendLog("  Input    : " + source.length() + " chars");
        appendLog("");

        String finalSource  = source;
        String finalLuaVer  = luaVer;

        executor.execute(() -> {
            // Load config text
            String configLua;
            try {
                configLua = ObfuscatorEngine.readConfig(this, presetId);
            } catch (IOException e) {
                publishError("Failed to read config '" + presetId + "': " + e.getMessage());
                return;
            }

            long t0 = System.currentTimeMillis();

            ObfuscatorEngine.Result result = ObfuscatorEngine.obfuscate(
                    this,
                    finalSource,
                    configLua,
                    finalLuaVer,
                    line -> mainHandler.post(() -> appendLog(line))
            );

            long elapsed = System.currentTimeMillis() - t0;

            mainHandler.post(() -> {
                setRunning(false);
                if (result.isSuccess()) {
                    etOutput.setText(result.output);
                    int lines = result.output.split("\n", -1).length;
                    tvOutputCount.setText(result.output.length() + " chars / " + lines + " lines");
                    appendLog("");
                    appendLog("✅ Done in " + elapsed + " ms  →  " + result.output.length() + " chars output");
                } else {
                    appendLog("");
                    appendLog("❌ Error: " + result.error);
                    Snackbar.make(btnObfuscate,
                            "Obfuscation failed — see logs",
                            Snackbar.LENGTH_LONG).show();
                }
                scrollLogsToBottom();
            });
        });
    }

    private void publishError(String msg) {
        mainHandler.post(() -> {
            setRunning(false);
            appendLog("❌ " + msg);
            toast(msg);
        });
    }

    private void setRunning(boolean r) {
        running = r;
        btnObfuscate.setEnabled(!r);
        progressBar.setVisibility(r ? View.VISIBLE : View.GONE);
        btnObfuscate.setText(r ? "Running…" : "🔥  Obfuscate");
    }

    // ── File I/O ──────────────────────────────────────────────────────────────

    private void openFilePicker() {
        Intent intent = new Intent(Intent.ACTION_GET_CONTENT);
        intent.setType("*/*");
        intent.addCategory(Intent.CATEGORY_OPENABLE);
        startActivityForResult(Intent.createChooser(intent, "Select Lua file"), REQ_OPEN_FILE);
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == REQ_OPEN_FILE && resultCode == Activity.RESULT_OK && data != null) {
            Uri uri = data.getData();
            if (uri == null) return;
            try (InputStream is = getContentResolver().openInputStream(uri)) {
                if (is == null) return;
                byte[] bytes = new byte[is.available()];
                is.read(bytes);
                String content = new String(bytes, "UTF-8");
                etInput.setText(content);
                // get display name
                String name = getFileName(uri);
                toast("Loaded: " + name);
            } catch (IOException e) {
                toast("Failed to read file: " + e.getMessage());
            }
        }
    }

    private String getFileName(Uri uri) {
        String result = uri.getLastPathSegment();
        try (android.database.Cursor cursor = getContentResolver().query(
                uri, null, null, null, null)) {
            if (cursor != null && cursor.moveToFirst()) {
                int idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME);
                if (idx >= 0) result = cursor.getString(idx);
            }
        } catch (Exception ignored) {}
        return result != null ? result : "unknown";
    }

    private void saveOutput() {
        String out = etOutput.getText().toString();
        if (out.isEmpty()) { toast("No output to save"); return; }

        try {
            String ts   = new SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(new Date());
            String name = "kreyzi_out_" + ts + ".lua";

            // Save to app's external files dir (no permission needed on API 29+)
            File dir = getExternalFilesDir(null);
            if (dir == null) dir = getFilesDir();
            dir.mkdirs();
            File f = new File(dir, name);

            try (FileWriter fw = new FileWriter(f)) { fw.write(out); }

            Snackbar.make(btnSaveOutput, "Saved → " + f.getAbsolutePath(), Snackbar.LENGTH_LONG)
                    .setAction("Share", v2 -> shareFile(f))
                    .show();
        } catch (IOException e) {
            toast("Save failed: " + e.getMessage());
        }
    }

    private void shareFile(File f) {
        try {
            Uri uri = FileProvider.getUriForFile(this,
                    getPackageName() + ".provider", f);
            Intent intent = new Intent(Intent.ACTION_SEND);
            intent.setType("text/plain");
            intent.putExtra(Intent.EXTRA_STREAM, uri);
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            startActivity(Intent.createChooser(intent, "Share obfuscated script"));
        } catch (Exception e) {
            toast("Share failed: " + e.getMessage());
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private void appendLog(String line) {
        String cur = tvLogs.getText().toString();
        tvLogs.setText(cur.isEmpty() ? line : cur + "\n" + line);
        scrollLogsToBottom();
    }

    private void scrollLogsToBottom() {
        svLogs.post(() -> svLogs.fullScroll(View.FOCUS_DOWN));
    }

    private void toast(String msg) {
        Toast.makeText(this, msg, Toast.LENGTH_SHORT).show();
    }
}
