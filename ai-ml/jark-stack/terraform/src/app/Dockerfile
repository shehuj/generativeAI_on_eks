FROM python:3.8-slim

RUN groupadd --gid 1000 appuser \
    && useradd --uid 1000 --gid 1000 -ms /bin/bash appuser

RUN pip3 install --no-cache-dir --upgrade \
    pip \
    virtualenv

RUN apt-get update && apt-get install -y

USER appuser
WORKDIR /home/appuser

ENV VIRTUAL_ENV=/home/appuser/venv
RUN virtualenv ${VIRTUAL_ENV}
RUN . ${VIRTUAL_ENV}/bin/activate && \
    pip install requests streamlit Pillow

EXPOSE 8501

COPY --chown=appuser:appuser streamlit.py /home/appuser/
COPY --chown=appuser:appuser run.sh /home/appuser/
# Invoke via bash so it works regardless of the file's execute bit.
ENTRYPOINT ["bash", "/home/appuser/run.sh"]
