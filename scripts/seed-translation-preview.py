#!/usr/bin/env python3
"""Seed disposable native-preview translation rows from synthetic preview PNGs.
Quit the isolated preview first. Never reads or modifies the real account cache.
All jobs are completed/failed, and the endpoint is .invalid: no work is submitted.
"""
import json
from pathlib import Path
import shutil
import time
import uuid

root = Path(__file__).resolve().parents[1]
fixtures = root / ".build/native-ui-preview/fixtures"
accounts = [p for p in (fixtures / "cache").iterdir() if p.is_dir()]
if len(accounts) != 1:
    raise SystemExit("Build/open the isolated native preview first; expected one fixture account.")
account = accounts[0]
images = [p for p in (fixtures / "media").rglob("*.png") if "Recycle" not in p.parts][:6]
if len(images) != 6:
    raise SystemExit("Synthetic preview PNGs are missing.")
directory = account / "image-translations"
directory.mkdir(exist_ok=True)
options = dict(detectionSize=1536, detector="default", direction="auto", translator="youdao", targetLanguage="ENG",
               inpaintingSize=2048, unclipRatio=2.3, boxThreshold=0.7, maskDilationOffset=30, inpainter="default")
jobs = []
for chapter, title, failed in [("c1-1", "Beyond the Blue · Chapter 2", False), ("c2-1", "Paper Moon · Chapter 2", True)]:
    job_id = str(uuid.uuid4())
    folder = directory / job_id
    folder.mkdir()
    pages = []
    for index, image in enumerate(images):
        page = dict(canonical=index, sourceMediaId="synthetic-source", sourceIndex=index,
                    sourceName=image.name, status="pending", error="")
        if not failed or index < 2:
            name = f"{job_id}-{index + 1:06}.png"
            shutil.copyfile(image, folder / name)
            page.update(status="committed", cachedName=name)
        elif index == 2:
            page.update(status="failed", error="Synthetic example: GPU worker unavailable.")
        pages.append(page)
    jobs.append(dict(id=job_id, ownerId=account.name, chapterId=chapter, title=title,
        description="Synthetic UI fixture. No image-service request was submitted.",
        addedAt=time.time() - 978307200, baseURL="https://image-translation-fixtures.invalid/api",
        options=options, destinationId="fixture-root", targetMediaId=str(uuid.uuid4()),
        sourceMedia=dict(id="synthetic-source", language="ja", kind="images", storageRootId="fixture-root",
                         relativePaths=[p.name for p in images], pageCount=6),
        pages=pages, status="failed" if failed else "completed",
        detail="Translation needs attention" if failed else "All translated pages are organized.",
        error="Synthetic example: GPU worker unavailable." if failed else ""))
(directory / "queue.json").write_text(json.dumps(jobs))
print("Seeded two synthetic preview chapters with cached page images; no network requests.")
