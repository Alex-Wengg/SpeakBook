#!/bin/bash
# Download PocketTTS models from HuggingFace

set -e

REPO="hexgrad/Kokoro-82M"
DEST="pocket-tts"

mkdir -p "$DEST/constants_bin/mimi_init_state"
mkdir -p "$DEST/constants_bin/alba_voice_cache"

echo "Downloading PocketTTS models..."

# Core models
curl -L "https://huggingface.co/$REPO/resolve/main/coreml/cond_step.mlmodelc.zip" -o "$DEST/cond_step.mlmodelc.zip"
curl -L "https://huggingface.co/$REPO/resolve/main/coreml/cond_step_v2.mlmodelc.zip" -o "$DEST/cond_step_v2.mlmodelc.zip"
curl -L "https://huggingface.co/$REPO/resolve/main/coreml/flowlm_step.mlmodelc.zip" -o "$DEST/flowlm_step.mlmodelc.zip"
curl -L "https://huggingface.co/$REPO/resolve/main/coreml/flow_decoder_v2.mlmodelc.zip" -o "$DEST/flow_decoder_v2.mlmodelc.zip"
curl -L "https://huggingface.co/$REPO/resolve/main/coreml/mimi_decoder_v2.mlmodelc.zip" -o "$DEST/mimi_decoder_v2.mlmodelc.zip"

# Unzip models
echo "Extracting models..."
for zip in "$DEST"/*.zip; do
    unzip -o "$zip" -d "$DEST"
    rm "$zip"
done

# Constants
echo "Downloading constants..."
curl -L "https://huggingface.co/$REPO/resolve/main/coreml/constants_bin/bos_emb.bin" -o "$DEST/constants_bin/bos_emb.bin"
curl -L "https://huggingface.co/$REPO/resolve/main/coreml/constants_bin/emb_mean.bin" -o "$DEST/constants_bin/emb_mean.bin"
curl -L "https://huggingface.co/$REPO/resolve/main/coreml/constants_bin/emb_std.bin" -o "$DEST/constants_bin/emb_std.bin"
curl -L "https://huggingface.co/$REPO/resolve/main/coreml/constants_bin/text_embed_table.bin" -o "$DEST/constants_bin/text_embed_table.bin"
curl -L "https://huggingface.co/$REPO/resolve/main/coreml/constants_bin/quantizer_weight.bin" -o "$DEST/constants_bin/quantizer_weight.bin"
curl -L "https://huggingface.co/$REPO/resolve/main/coreml/constants_bin/tokenizer.model" -o "$DEST/constants_bin/tokenizer.model"
curl -L "https://huggingface.co/$REPO/resolve/main/coreml/constants_bin/manifest.json" -o "$DEST/constants_bin/manifest.json"

# Voice prompts
echo "Downloading voice prompts..."
for voice in alba heart bella jean javert fantine cosette eponine marius azelma; do
    curl -L "https://huggingface.co/$REPO/resolve/main/coreml/constants_bin/${voice}_audio_prompt.bin" -o "$DEST/constants_bin/${voice}_audio_prompt.bin" 2>/dev/null || true
done

# Mimi init state
echo "Downloading mimi init state..."
for f in attn0_cache attn0_end_offset attn0_offset attn1_cache attn1_end_offset attn1_offset \
         conv0_first conv0_prev conv_final_first conv_final_prev \
         convtr0_partial convtr1_partial convtr2_partial upsample_partial \
         res0_conv0_first res0_conv0_prev res0_conv1_first res0_conv1_prev \
         res1_conv0_first res1_conv0_prev res1_conv1_first res1_conv1_prev \
         res2_conv0_first res2_conv0_prev res2_conv1_first res2_conv1_prev; do
    curl -L "https://huggingface.co/$REPO/resolve/main/coreml/constants_bin/mimi_init_state/${f}.bin" -o "$DEST/constants_bin/mimi_init_state/${f}.bin"
done

# Symlink flow_decoder
ln -sf flow_decoder_v2.mlmodelc "$DEST/flow_decoder.mlmodelc"

echo "Done! Models downloaded to $DEST/"
