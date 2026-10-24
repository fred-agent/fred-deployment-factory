ARG PYTHON_BASE=python:3.12-slim@sha256:a0f57064cbdcd6285fa45f51237ab0b35ea8ebaed06a1f5973e89e19dfb86704
FROM ${PYTHON_BASE}

RUN python -m pip install --no-cache-dir uv==0.11.1 \
    && uv pip install --system --no-cache \
      duckdb==1.4.1 \
      openpyxl==3.1.5 \
      pandas==2.3.3 \
      pypdf==6.1.1 \
      python-docx==1.2.0 \
      python-pptx==1.0.2 \
    && python -c 'import docx, duckdb, openpyxl, pandas, pptx, pypdf'
