#!/usr/bin/env python3
from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path

import numpy as np
import onnx
from onnx import numpy_helper


def main() -> int:
    if len(sys.argv) != 4:
        print(
            "usage: bucketize-whisper-onnx.py <source_model_dir> <target_dir> <nb_max_frames>",
            file=sys.stderr,
        )
        return 1

    source = Path(sys.argv[1]).expanduser()
    target = Path(sys.argv[2]).expanduser()
    nb_max_frames = int(sys.argv[3])

    if nb_max_frames % 2 != 0:
        print("nb_max_frames must be even", file=sys.stderr)
        return 1

    encoder_steps = nb_max_frames // 2
    n_samples = nb_max_frames * 160
    chunk_length = nb_max_frames / 100.0

    if target.exists():
        shutil.rmtree(target)
    target.mkdir(parents=True)
    (target / "onnx").mkdir(parents=True)

    for name in [
        "config.json",
        "generation_config.json",
        "preprocessor_config.json",
        "tokenizer.json",
        "tokenizer_config.json",
        "special_tokens_map.json",
        "added_tokens.json",
        "merges.txt",
        "normalizer.json",
        "vocab.json",
    ]:
        src = source / name
        if src.exists():
            shutil.copy2(src, target / name)

    encoder_src = source / "onnx" / "encoder_model_int8.onnx"
    encoder_model = onnx.load(str(encoder_src), load_external_data=True)

    def patch_value_info_shape(value_info: onnx.ValueInfoProto) -> None:
        tensor = value_info.type.tensor_type
        for dim in tensor.shape.dim:
            if dim.HasField("dim_value"):
                if dim.dim_value == 3000:
                    dim.dim_value = nb_max_frames
                elif dim.dim_value == 1500:
                    dim.dim_value = encoder_steps

    for value_info in list(encoder_model.graph.input) + list(encoder_model.graph.output) + list(
        encoder_model.graph.value_info
    ):
        patch_value_info_shape(value_info)

    for idx, init in enumerate(list(encoder_model.graph.initializer)):
        arr = numpy_helper.to_array(init)
        patched_arr = arr
        changed = False

        if list(init.dims) == [1500, 1280]:
            patched_arr = arr[:encoder_steps, :].copy()
            changed = True
        elif np.issubdtype(arr.dtype, np.integer):
            patched_arr = arr.copy()
            mask1500 = patched_arr == 1500
            mask3000 = patched_arr == 3000
            if mask1500.any() or mask3000.any():
                patched_arr[mask1500] = encoder_steps
                patched_arr[mask3000] = nb_max_frames
                changed = True

        if changed:
            new_init = numpy_helper.from_array(patched_arr, init.name)
            encoder_model.graph.initializer.remove(init)
            encoder_model.graph.initializer.insert(idx, new_init)

    encoder_out = target / "onnx" / "encoder_model_int8.onnx"
    onnx.save(
        encoder_model,
        str(encoder_out),
        save_as_external_data=True,
        all_tensors_to_one_file=True,
        location="encoder_model_int8.onnx.data",
        size_threshold=1024,
    )

    for name in ["decoder_model_int8.onnx", "decoder_with_past_model_int8.onnx"]:
        shutil.copy2(source / "onnx" / name, target / "onnx" / name)

    for name in [
        "encoder_model_int8.onnx.data",
        "decoder_model_int8.onnx.data",
        "decoder_with_past_model_int8.onnx.data",
        "encoder_model_int8.onnx_data",
        "decoder_model_int8.onnx_data",
        "decoder_with_past_model_int8.onnx_data",
    ]:
        src = source / "onnx" / name
        dst = target / "onnx" / name
        if src.exists() and not dst.exists():
            shutil.copy2(src, dst)

    config_path = target / "config.json"
    if config_path.exists():
        config = json.loads(config_path.read_text())
        config["max_source_positions"] = encoder_steps
        config_path.write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n")

    preprocessor_path = target / "preprocessor_config.json"
    if preprocessor_path.exists():
        preprocessor = json.loads(preprocessor_path.read_text())
        preprocessor["nb_max_frames"] = nb_max_frames
        preprocessor["n_samples"] = n_samples
        preprocessor["chunk_length"] = chunk_length
        preprocessor_path.write_text(
            json.dumps(preprocessor, ensure_ascii=False, indent=2) + "\n"
        )

    encoder_root = target / "encoder_model.static_qop.onnx"
    encoder_reloaded = onnx.load(str(encoder_out), load_external_data=True)
    onnx.save(
        encoder_reloaded,
        str(encoder_root),
        save_as_external_data=True,
        all_tensors_to_one_file=True,
        location="encoder_model.static_qop.onnx.data",
        size_threshold=1024,
    )
    shutil.copy2(target / "onnx" / "decoder_model_int8.onnx", target / "decoder_model.dynamic_int8.onnx")
    shutil.copy2(
        target / "onnx" / "decoder_with_past_model_int8.onnx",
        target / "decoder_with_past_model.dynamic_int8.onnx",
    )
    (target / ".wrenflow-model-ready").touch()

    print(
        f"wrote bucketed bundle to {target} with nb_max_frames={nb_max_frames}, "
        f"encoder_steps={encoder_steps}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
