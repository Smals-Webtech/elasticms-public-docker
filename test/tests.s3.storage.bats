#!/usr/bin/env bats
load "helpers/tests"
load "helpers/docker"
load "helpers/dataloaders"

load "lib/batslib"
load "lib/output"

export BATS_ROOT_DB_USER="${BATS_ROOT_DB_USER:-root}"
export BATS_ROOT_DB_PASSWORD="${BATS_ROOT_DB_PASSWORD:-password}"
export BATS_ROOT_DB_NAME="${BATS_ROOT_DB_PASSWORD:-root}"

export BATS_DB_DRIVER="${BATS_DB_DRIVER:-pgsql}"
export BATS_DB_HOST="${BATS_DB_HOST:-postgresql}"
export BATS_DB_PORT="${BATS_DB_PORT:-5432}"
export BATS_DB_USER="${BATS_DB_USER:-example_adm}"
export BATS_DB_PASSWORD="${BATS_DB_PASSWORD:-example}"
export BATS_DB_NAME="${BATS_DB_NAME:-example}"

export BATS_REDIS_HOST="${BATS_REDIS_HOST:-redis}"
export BATS_REDIS_PORT="${BATS_REDIS_PORT:-6379}"

export BATS_S3_CONFIG_BUCKET_NAME="s3bucket-ems-config/example/config/elasticms"
export BATS_S3_STORAGE_BUCKET_NAME="s3bucket-example-ems-storage"
export BATS_S3_ENDPOINT_URL="http://localhost:4572"
export BATS_S3_ACCESS_KEY_ID="mock"
export BATS_S3_SECRET_ACCESS_KEY="mock"
export BATS_S3_DEFAULT_REGION="us-east-1"

export BATS_PGSQL_VOLUME_NAME=${BATS_PGSQL_VOLUME_NAME:-postgresql_data}
export BATS_ES_1_VOLUME_NAME=${BATS_ES_1_VOLUME_NAME:-elasticsearch_data_1}
export BATS_ES_2_VOLUME_NAME=${BATS_ES_2_VOLUME_NAME:-elasticsearch_data_2}
export BATS_EMS_CONFIG_VOLUME_NAME=${BATS_EMS_CONFIG_VOLUME_NAME:-ems_configmap}
export BATS_EMS_STORAGE_VOLUME_NAME=${BATS_EMS_STORAGE_VOLUME_NAME:-ems_storage}
export BATS_REDIS_VOLUME_NAME=${BATS_REDIS_VOLUME_NAME:-redis_storage}

export AWS_ACCESS_KEY_ID="${BATS_S3_ACCESS_KEY_ID}"
export AWS_SECRET_ACCESS_KEY="${BATS_S3_SECRET_ACCESS_KEY}"
export AWS_DEFAULT_REGION="${BATS_S3_DEFAULT_REGION}"

export BATS_CLAIR_LOCAL_SCANNER_CONFIG_VOLUME_NAME=${BATS_CLAIR_LOCAL_SCANNER_CONFIG_VOLUME_NAME:-clair_local_scanner}

export BATS_PHP_FPM_MAX_CHILDREN="${BATS_PHP_FPM_MAX_CHILDREN:-4}"
export BATS_PHP_FPM_REQUEST_MAX_MEMORY_IN_MEGABYTES="${BATS_PHP_FPM_REQUEST_MAX_MEMORY_IN_MEGABYTES:-128}"
export BATS_CONTAINER_HEAP_PERCENT="${BATS_CONTAINER_HEAP_PERCENT:-0.80}"

export BATS_STORAGE_SERVICE_NAME="postgresql"

export BATS_EMS_DOCKER_IMAGE_NAME="${EMS_DOCKER_IMAGE_NAME:-docker.io/elasticms/admin}:rc"

@test "[$TEST_FILE] Create Docker external volumes (local)" {
  command docker volume create -d local ${BATS_PGSQL_VOLUME_NAME}
  command docker volume create -d local ${BATS_ES_1_VOLUME_NAME}
  command docker volume create -d local ${BATS_ES_2_VOLUME_NAME}
  command docker volume create -d local ${BATS_CLAIR_LOCAL_SCANNER_CONFIG_VOLUME_NAME}
  command docker volume create -d local ${BATS_REDIS_VOLUME_NAME}
}

@test "[$TEST_FILE] Pull all Docker images" {
  command docker-compose -f docker-compose-s3.yml pull
}

@test "[$TEST_FILE] Starting Elasticms Storage Services (S3, PostgreSQL, Elasticsearch, Redis)" {
  command docker-compose -f docker-compose-s3.yml up -d s3 postgresql elasticsearch_1 elasticsearch_2 redis
  docker_wait_for_log postgresql 240 "LOG:  autovacuum launcher started"
  docker_wait_for_log elasticsearch_1 240 "\[INFO \]\[o.e.n.Node.*\] \[.*\] started"
  docker_wait_for_log elasticsearch_2 240 "\[INFO \]\[o.e.n.Node.*\] \[.*\] started"
  docker_wait_for_log s3 240 "Ready."
  docker_wait_for_log redis 240 "Ready to accept connections"
}

@test "[$TEST_FILE] Starting Tika Service" {
  command docker-compose -f docker-compose-s3.yml up -d tika
  docker_wait_for_log tika 120 ".*Started Apache Tika server.*"
}

@test "[$TEST_FILE] Loading Config files in Elasticms Configuration S3 Bucket" {
  run aws s3 mb s3://${BATS_S3_CONFIG_BUCKET_NAME%/} --endpoint-url ${BATS_S3_ENDPOINT_URL}
  assert_output -l -r "make_bucket: ${BATS_S3_CONFIG_BUCKET_NAME%%/*}"

  run aws s3api put-bucket-acl --bucket s3://${BATS_S3_CONFIG_BUCKET_NAME%/} --acl public-read --endpoint-url ${BATS_S3_ENDPOINT_URL}

  for file in ${BATS_TEST_DIRNAME%/}/config/s3/*.properties ; do
    _basename=$(basename $file)
    _name=${_basename%.*}

    run init_ems_config_s3bucket $file ${BATS_S3_CONFIG_BUCKET_NAME%/}/ $BATS_S3_ENDPOINT_URL 
    assert_output -l -r 'S3 EMS CONFIG COPY OK'

  done
}

@test "[$TEST_FILE] Loading Test Data files in Elasticms Storage services (S3 / DB)" {
  run aws s3 mb s3://${BATS_S3_STORAGE_BUCKET_NAME%/} --endpoint-url ${BATS_S3_ENDPOINT_URL}
  assert_output -l -r "make_bucket: $BATS_S3_STORAGE_BUCKET_NAME"

  run aws s3api put-bucket-acl --bucket s3://${BATS_S3_STORAGE_BUCKET_NAME%/} --acl public-read --endpoint-url ${BATS_S3_ENDPOINT_URL}

  for file in ${BATS_TEST_DIRNAME%/}/config/s3/*.properties ; do
    _basename=$(basename $file)
    _name=${_basename%.*}

    envsubst < $file > /tmp/$_name
    source /tmp/$_name

    run load_database $BATS_STORAGE_SERVICE_NAME $file ${BATS_DB_DRIVER} $BATS_ROOT_DB_USER $BATS_ROOT_DB_PASSWORD $BATS_ROOT_DB_NAME $BATS_DB_PORT $BATS_DB_HOST $BATS_DB_USER $BATS_DB_PASSWORD $BATS_DB_NAME
    assert_output -l -r "${BATS_DB_DRIVER} OK"

    run init_ems_data_s3bucket $file $BATS_S3_STORAGE_BUCKET_NAME $BATS_S3_ENDPOINT_URL 
    assert_output -l -r 'S3 EMS DATA COPY OK'

    rm /tmp/$_name

  done
}

@test "[$TEST_FILE] Starting Elasticms services (webserver, php-fpm) configured for AWS S3" {
  export BATS_ES_LOCAL_ENDPOINT_URL=http://$(docker_ip elasticsearch_1):9200
  export BATS_S3_ENDPOINT_URL=http://$(docker_ip s3):4572
  export BATS_TIKA_LOCAL_ENDPOINT_URL=http://$(docker_ip tika):9998
  export BATS_REDIS_HOST=$(docker_ip redis)

  command docker-compose -f docker-compose-s3.yml up -d elasticms

}

@test "[$TEST_FILE] Check for Elasticms startup messages in containers logs (S3)" {
  for file in ${BATS_TEST_DIRNAME%/}/config/s3/*.properties ; do
    _basename=$(basename $file)
    _name=${_basename%.*}
    docker_wait_for_log ems 15 "Install \[ ${_name} \] CMS Domain from S3 Bucket \[ ${_basename} \] file successfully ..."
    docker_wait_for_log ems 15 "Doctrine database migration for \[ ${_name} \] CMS Domain run successfully ..."
    docker_wait_for_log ems 15 "Elasticms assets installation for \[ ${_name} \] CMS Domain run successfully ..."
    docker_wait_for_log ems 15 "Elasticms warming up for \[ ${_name} \] CMS Domain run successfully ..."
  done

  docker_wait_for_log ems 15 "NOTICE: ready to handle connections"
  docker_wait_for_log ems 15 "AH00292: Apache/.* \(Unix\) OpenSSL/.* configured -- resuming normal operations"

}

@test "[$TEST_FILE] Create Elasticms Super Admin user in running container for all configured domains (S3)" {
  for file in ${BATS_TEST_DIRNAME%/}/config/s3/*.properties ; do
    _basename=$(basename $file)
    _name=${_basename%.*}

    envsubst < $file > /tmp/$_name
    source /tmp/$_name

    run docker exec ems sh -c "/opt/bin/$_name fos:user:create --super-admin ${_name}-bats ${_name}.admin.s3.bats@example.com bats"
    assert_output -l 0 "Created user ${_name}-bats"

    rm /tmp/$_name

  done
}

@test "[$TEST_FILE] Rebuild Elasticms Environments for all configured domains (S3)" {
  for file in ${BATS_TEST_DIRNAME%/}/config/s3/*.properties ; do
    _basename=$(basename $file)
    _name=${_basename%.*}

    environments=(`docker exec ems sh -c "/opt/bin/$_name ems:environment:list"`)

    for environment in ${environments[@]}; do

      run docker exec ems sh -c "/opt/bin/$_name ems:environment:rebuild $environment --yellow-ok"
      assert_output -l -r "The alias ${environment} is now pointing to"

    done

  done
}

@test "[$TEST_FILE] Check for Redis session handler" {
  run docker exec -it redis sh -c ". /opt/rh/rh-redis5/enable && redis-cli --scan"
  assert_output -l -r "^.*sf.*$"
}

@test "[$TEST_FILE] Check for Elasticms Default Index page response code 200" {
  retry 12 5 curl_container ems :9000/index.php -H 'Host: default.localhost' -s -w %{http_code} -o /dev/null
  assert_output -l 0 $'200'
}

@test "[$TEST_FILE] Check for Elasticms status page response code 200 for all configured domains (S3)" {
  for file in ${BATS_TEST_DIRNAME%/}/config/s3/*.properties ; do
    _basename=$(basename $file)
    _name=${_basename%.*}

    envsubst < $file > /tmp/$_name
    source /tmp/$_name

    retry 12 5 curl_container ems :9000/status -H "'Host: ${SERVER_NAME}'" -s -w %{http_code} -o /dev/null
    assert_output -l 0 $'200'

    retry 12 5 curl_container ems :9000/cluster/ -H "'Host: ${SERVER_NAME}'" -s -w %{http_code} -o /dev/null
    assert_output -l 0 $'200'

    retry 12 5 curl_container ems :9000/health_check.json -H "'Host: ${SERVER_NAME}'" -s -w %{http_code} -o /dev/null
    assert_output -l 0 $'200'

    rm /tmp/$_name

  done
}

@test "[$TEST_FILE] Check for Monitoring /real-time-status page response code 200" {
  retry 12 5 curl_container ems :9000/real-time-status -H 'Host: default.localhost' -s -w %{http_code} -o /dev/null
  assert_output -l 0 $'200'
}

@test "[$TEST_FILE] Check for Monitoring /status page response code 200" {
  retry 12 5 curl_container ems :9000/status -H 'Host: default.localhost' -s -w %{http_code} -o /dev/null
  assert_output -l 0 $'200'
}

@test "[$TEST_FILE] Check for Monitoring /server-status page response code 200" {
  retry 12 5 curl_container ems :9000/server-status -H 'Host: default.localhost' -s -w %{http_code} -o /dev/null
  assert_output -l 0 $'200'
}

@test "[$TEST_FILE] Stop all and delete test containers" {
  command docker-compose -f docker-compose-s3.yml stop
  command docker-compose -f docker-compose-s3.yml rm -v -f  
}

@test "[$TEST_FILE] Cleanup Docker external volumes (local)" {
  command docker volume rm ${BATS_PGSQL_VOLUME_NAME}
  command docker volume rm ${BATS_ES_1_VOLUME_NAME}
  command docker volume rm ${BATS_ES_2_VOLUME_NAME}
  command docker volume rm ${BATS_CLAIR_LOCAL_SCANNER_CONFIG_VOLUME_NAME} 
  command docker volume rm ${BATS_REDIS_VOLUME_NAME} 
}