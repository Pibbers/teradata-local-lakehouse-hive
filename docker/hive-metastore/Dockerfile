FROM docker-hive-metastore:latest

# Iceberg Hive runtime provides HiveIcebergStorageHandler and HiveIcebergSerDe,
# which HMS needs to process Iceberg metadata commits from Teradata OTF.
# Without this JAR the snapshot commit phase silently fails even though the
# Parquet data files are written to object storage successfully.
RUN wget -q -P /opt/hive/lib/ \
    https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-hive-runtime/1.6.1/iceberg-hive-runtime-1.6.1.jar

# Manage hive-site.xml in this repo so MinIO credentials are driven by env vars
# (MINIO_ROOT_USER / MINIO_ROOT_PASSWORD) substituted at container startup via envsubst.
COPY hive-site.xml /opt/hive/conf/hive-site.xml
