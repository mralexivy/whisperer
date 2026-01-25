# Manual Model Download (If Automatic Fails)

If the automatic download doesn't work, manually download the model:

## Step 1: Download Model

Open Terminal and run:

```bash
# Create directory
mkdir -p ~/Library/Application\ Support/Whisperer

# Download model (1.5GB - may take 5-10 minutes)
curl -L -o ~/Library/Application\ Support/Whisperer/ggml-large-v3-turbo.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin

# Verify download
ls -lh ~/Library/Application\ Support/Whisperer/
```

You should see: `ggml-large-v3-turbo.bin` (~1.5GB)

## Step 2: Verify Model Location

```bash
# Check the file exists
file ~/Library/Application\ Support/Whisperer/ggml-large-v3-turbo.bin
```

Should output: `data` (binary file)

## Step 3: Restart Whisperer

1. Quit Whisperer app
2. Relaunch it
3. The app should detect the model and skip download

## Troubleshooting

**Download fails with curl?**

Try with browser:
1. Visit: https://huggingface.co/ggerganov/whisper.cpp/tree/main
2. Download `ggml-large-v3-turbo.bin`
3. Move to: `~/Library/Application Support/Whisperer/`

**Wrong location?**

Make sure the path is exactly:
```
/Users/YOUR_USERNAME/Library/Application Support/Whisperer/ggml-large-v3-turbo.bin
```

**Still not working?**

Check Xcode console for the exact path the app is looking for.
