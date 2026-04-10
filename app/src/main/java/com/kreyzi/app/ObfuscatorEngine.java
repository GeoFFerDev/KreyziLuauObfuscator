package com.kreyzi.app;

import android.content.Context;
import android.util.Log;

import org.luaj.vm2.Globals;
import org.luaj.vm2.LuaString;
import org.luaj.vm2.LuaValue;
import org.luaj.vm2.lib.jse.JsePlatform;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.PrintStream;
import java.io.ByteArrayOutputStream;

/**
 * Wraps the Kreyzi/Prometheus Lua obfuscator pipeline inside LuaJ.
 * Call ObfuscatorEngine.obfuscate() from a background thread.
 */
public class ObfuscatorEngine {

    private static final String TAG = "KreyziEngine";
    private static final String LUA_DIR = "lua"; // assets sub-folder
    private static final String ASSETS_VERSION_FILE = "assets_version.txt";
    private static final int    CURRENT_VERSION = 3;

    public interface ProgressListener {
        void onLog(String line);
    }

    // ── Public API ───────────────────────────────────────────────────────────

    public static class Result {
        public final String output;
        public final String logs;
        public final String error;
        public Result(String output, String logs, String error) {
            this.output = output;
            this.logs   = logs;
            this.error  = error;
        }
        public boolean isSuccess() { return error == null && output != null; }
    }

    /**
     * @param context        app context (needed for asset extraction)
     * @param source         raw Lua source to obfuscate
     * @param configLua      Lua chunk that returns a config table (e.g. content of roblox_light.lua)
     * @param luaVersion     "LuaU", "Lua51", or "" (use config default)
     * @param listener       optional log callback (called on calling thread)
     */
    public static Result obfuscate(Context context,
                                   String source,
                                   String configLua,
                                   String luaVersion,
                                   ProgressListener listener) {
        // 1. Extract assets to files dir (idempotent / version-gated)
        File luaRoot;
        try {
            luaRoot = ensureAssetsExtracted(context);
        } catch (IOException e) {
            return new Result(null, "", "Failed to extract Lua assets: " + e.getMessage());
        }

        String basePath = luaRoot.getAbsolutePath() + "/";

        // 2. Read android_entry.lua from extracted files
        File entryFile = new File(luaRoot, "android_entry.lua");
        String entryScript;
        try {
            entryScript = readFile(entryFile);
        } catch (IOException e) {
            return new Result(null, "", "Cannot read entry script: " + e.getMessage());
        }

        // 3. Capture stdout / stderr
        ByteArrayOutputStream logBuffer = new ByteArrayOutputStream();
        PrintStream logStream = new PrintStream(logBuffer);
        PrintStream oldOut = System.out;
        PrintStream oldErr = System.err;
        System.setOut(logStream);
        System.setErr(logStream);

        String output = null;
        String error  = null;

        try {
            // 4. Create LuaJ globals — debugGlobals() includes the debug library
            //    (standardGlobals() omits it, causing "index expected, got nil" on debug.getinfo)
            Globals globals = JsePlatform.debugGlobals();

            // 5. Inject our variables
            globals.set("KREYZI_BASE",   LuaString.valueOf(basePath));
            globals.set("KREYZI_SOURCE", LuaString.valueOf(source));
            globals.set("KREYZI_CONFIG", LuaString.valueOf(configLua));
            globals.set("KREYZI_LUAVER", luaVersion != null ? LuaString.valueOf(luaVersion) : LuaValue.NIL);

            // 6. Execute entry script
            LuaValue chunk = globals.load(entryScript, "android_entry");
            chunk.call();

            // 7. Collect results
            LuaValue outVal = globals.get("KREYZI_OUTPUT");
            LuaValue errVal = globals.get("KREYZI_ERROR");

            if (!errVal.isnil()) {
                error = errVal.tojstring();
            } else if (!outVal.isnil()) {
                output = outVal.tojstring();
            } else {
                error = "Pipeline returned no output and no error.";
            }

        } catch (Exception e) {
            Log.e(TAG, "LuaJ exception", e);
            error = e.getMessage();
            if (error == null) error = e.getClass().getSimpleName();
        } finally {
            System.setOut(oldOut);
            System.setErr(oldErr);
        }

        String logs = logBuffer.toString();
        if (listener != null) {
            for (String line : logs.split("\n")) {
                listener.onLog(line);
            }
        }

        return new Result(output, logs, error);
    }

    // ── Asset extraction ─────────────────────────────────────────────────────

    private static File ensureAssetsExtracted(Context ctx) throws IOException {
        File luaRoot = new File(ctx.getFilesDir(), "lua");

        // Version check: re-extract only when assets change
        File versionFile = new File(ctx.getFilesDir(), ASSETS_VERSION_FILE);
        if (versionFile.exists()) {
            try {
                String v = readFile(versionFile).trim();
                if (Integer.parseInt(v) == CURRENT_VERSION && luaRoot.exists()) {
                    return luaRoot; // already up to date
                }
            } catch (Exception ignored) {}
        }

        // Wipe old extracted files
        deleteDir(luaRoot);
        luaRoot.mkdirs();

        // Copy every asset under "lua/" recursively
        copyAssetFolder(ctx, LUA_DIR, luaRoot);

        // Write version stamp
        try (FileOutputStream fos = new FileOutputStream(versionFile)) {
            fos.write(String.valueOf(CURRENT_VERSION).getBytes());
        }

        return luaRoot;
    }

    private static void copyAssetFolder(Context ctx, String assetPath, File destDir) throws IOException {
        String[] list = ctx.getAssets().list(assetPath);
        if (list == null) return;

        if (list.length == 0) {
            // It's a file
            copyAsset(ctx, assetPath, destDir.getParentFile(), destDir.getName());
            return;
        }

        // It's a directory
        destDir.mkdirs();
        for (String item : list) {
            String childAsset = assetPath + "/" + item;
            File   childDest  = new File(destDir, item);

            String[] subList = ctx.getAssets().list(childAsset);
            if (subList != null && subList.length > 0) {
                childDest.mkdirs();
                copyAssetFolder(ctx, childAsset, childDest);
            } else {
                copyAsset(ctx, childAsset, destDir, item);
            }
        }
    }

    private static void copyAsset(Context ctx, String assetPath, File dir, String fileName) throws IOException {
        File dest = new File(dir, fileName);
        try (InputStream in  = ctx.getAssets().open(assetPath);
             OutputStream out = new FileOutputStream(dest)) {
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) != -1) out.write(buf, 0, n);
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private static String readFile(File f) throws IOException {
        try (InputStream in = new java.io.FileInputStream(f)) {
            byte[] data = new byte[(int) f.length()];
            int read = 0;
            while (read < data.length) {
                int n = in.read(data, read, data.length - read);
                if (n < 0) break;
                read += n;
            }
            return new String(data, "UTF-8");
        }
    }

    private static void deleteDir(File f) {
        if (f.isDirectory()) {
            File[] kids = f.listFiles();
            if (kids != null) for (File k : kids) deleteDir(k);
        }
        f.delete();
    }

    // ── Config file loader ────────────────────────────────────────────────────

    /** Read the Lua text of a named config from the extracted assets. */
    public static String readConfig(Context ctx, String configName) throws IOException {
        File luaRoot  = new File(ctx.getFilesDir(), "lua");
        File cfgFile  = new File(luaRoot, "configs/" + configName + ".lua");
        if (!cfgFile.exists()) {
            // fallback: extract first
            ensureAssetsExtracted(ctx);
        }
        return readFile(cfgFile);
    }
}
