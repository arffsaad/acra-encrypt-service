#!/bin/bash

# Acra-Server install script. Included with acra-encryptor configs and also key generation.

# urlencoding

urlencode() {
    # urlencode <string>

    old_lc_collate=$LC_COLLATE
    LC_COLLATE=C

    local length="${#1}"
    for (( i = 0; i < length; i++ )); do
        local c="${1:$i:1}"
        case $c in
            [a-zA-Z0-9.~_-]) printf '%s' "$c" ;;
            *) printf '%%%02X' "'$c" ;;
        esac
    done

    LC_COLLATE=$old_lc_collate
}

# go to home
cd ~
# create dir
mkdir acra
cd acra

# build acra-server from source

    # check if os is debian/ubuntu or centos/redhat

if [ -f /etc/debian_version ]; then

echo "Debian based OS detected."
sudo apt-get install git libssl-dev make build-essential -y
sudo apt install golang-go
sudo apt install mysql-client
sudo apt install postgresql-client


elif [ -f /etc/redhat-release ]; then

echo "RedHat based OS detected."
sudo yum groupinstall 'Development Tools' -y
sudo yum install openssl-devel -y
sudo yum install golang -y
sudo yum install mysql -y
sudo yum install postgresql -y

fi

# put go to path
echo 'export PATH=$PATH:${GOBIN:-${GOPATH:-$HOME}/go/bin}' >> ~/.bashrc
source ~/.bashrc

# install themis
echo "Installing Themis..."
git clone https://github.com/cossacklabs/themis.git
cd themis
make
sudo make install
echo 'export LD_LIBRARY_PATH=/usr/local/lib' >> ~/.bashrc
source ~/.bashrc
cd ~

# install keymaker and generate keys
echo "Installing Keymaker..."
go install github.com/cossacklabs/acra/cmd/acra-keymaker@latest
echo "Generating keys..."
acra-keymaker --keystore=v1 --generate_master_key=master.key
echo 'export ACRA_MASTER_KEY=$(cat master.key | base64)' >> ~/.bashrc
clear
echo "Installing Acra Server..."
go install github.com/cossacklabs/acra/cmd/acra-server@latest
source ~/.bashrc

acra-keymaker --client_id=dbEncrypt \
  --generate_acrawriter_keys \
  --generate_symmetric_storage_key \
  --generate_hmac_key \
  --generate_log_key \
  --keystore=v1

cd ~/
rm -rf acra
# generate server config
clear
echo "Generating server config..."
cd /etc
mkdir acra
cd acra
touch acra-server.yaml
echo 'version: 0.93.0' >> acra-server.yaml
echo 'client_id: dbEncrypt' >> acra-server.yaml
dbserver="none"
while [[ "$dbserver" != "M" ]] || [[ "$dbserver" != "P" ]] || [[ "$dbserver" != "m" ]] || [[ "$dbserver" != "p" ]] ; do
    read -p "What DB server are you using? ([M]ysql/[P]ostgres)" dbserver
    if [[ $dbserver == "M" ]] || [[ $dbserver == "m" ]]; then
        echo "mysql_enable: true" >> acra-server.yaml
        echo "postgresql_enable: false" >> acra-server.yaml
        break

    elif [[ $dbserver == "p" ]] || [[ $dbserver == "P" ]]; then
        echo "mysql_enable: false" >> acra-server.yaml
        echo "postgresql_enable: true" >> acra-server.yaml
        break
    else
        echo "Please enter M or P"
    fi
done
read -p "Which port is your DB server running on: " dbport
echo "db_port: $dbport" >> acra-server.yaml
read -p "What is your DB server address: " dbhost
echo "db_host: $dbhost" >> acra-server.yaml
echo "zonemode_enable: false" >> acra-server.yaml
echo 'encryptor_config_file: "/etc/acra/acra-encryptor.yaml"' >> acra-server.yaml

touch acra-encryptor.yaml

clear
if [[ $dbserver == "M" ]] || [[ $dbserver == "m" ]]; then
    echo "Generating encryptor config interactively..."
    # Log into mysql
    function mysqllogin() {
        echo "Please log into your mysql server."
        read -p "Enter Username: " dbuser
        echo -n "Enter Password: "
        read -s dbpass
        #check if conn.cnf exists
        if [ -f conn.cnf ]; then
            rm -f conn.cnf
        fi
        touch conn.cnf

        echo 'schemas:' >> acra-encryptor.yaml

        echo "[client]" >> conn.cnf
        echo "host=$dbhost" >> conn.cnf
        echo "user=$dbuser" >> conn.cnf
        echo "password=$dbpass" >> conn.cnf
    }
    columnTypeArr=("blank" "str" "email" "int64" "int32" "bytes")

    mysqllogin
    # create function
    getDatabases() {
        mapfile dbs < <(mysql --defaults-extra-file=conn.cnf --batch -se "SHOW DATABASES;")
        clear
        echo "Listing databases..."
        #if dbs is empty, exit
        while [ ${#dbs[@]} -eq 0 ]; do
            echo "No databases found. Check your password or access levels."
            mysqllogin
            mapfile dbs < <(mysql --defaults-extra-file=conn.cnf --batch -se "SHOW DATABASES;")
        done
        dbs=("blank" "${dbs[@]}")
        for (( i=0; i<${#dbs[@]}; i++ ))
            do
                if [[ ${dbs[$i]} != "blank"  ]]; then
                    echo $(($i)). ${dbs[$i]}
                fi
        done

        read -p "Select DB: " dbselect
        dbname=${dbs[$dbselect]}
        dbname=${dbname//[$'\t\r\n ']}

    }
    getTables() {
        clear
        echo "Listing tables..."
        mapfile tables < <(mysql --defaults-extra-file=conn.cnf --batch -se "SELECT table_name FROM information_schema.tables WHERE table_schema = \"$1\";")
        tables=("blank" "${tables[@]}")
        for (( i=0; i<${#tables[@]}; i++ ))
            do
                if [[ ${tables[$i]} != "blank"  ]]; then
                    echo $(($i)). ${tables[$i]}
                fi
        done

        read -p "Which table do you want to encrypt: " dbtableselect
        dbtable=${tables[$dbtableselect]}
        dbtable=${dbtable//[$'\t\r\n ']}
        echo "  - table: $dbtable" >> acra-encryptor.yaml
        echo "    columns:" >> acra-encryptor.yaml
        mapfile columns < <(mysql --defaults-extra-file=conn.cnf --batch -se 'SELECT `COLUMN_NAME` FROM `INFORMATION_SCHEMA`.`COLUMNS` WHERE `TABLE_SCHEMA`="'$dbname'" AND `TABLE_NAME`="'$dbtable'";')
        columns=("blank" "${columns[@]}")
        for (( i=0; i<${#columns[@]}; i++ ))
            do
                if [[ ${columns[$i]} != "blank"  ]]; then
                    conv=${columns[$i]}
                    conv=${conv//[$'\t\r\n ']}
                    echo "      - $conv" >> acra-encryptor.yaml
                fi
        done
        echo "    encrypted:" >> acra-encryptor.yaml
    }

    getColumns() {
        clear
        echo "Listing Columns..."
        mapfile results < <(mysql --defaults-extra-file=conn.cnf --batch -se 'SELECT `COLUMN_NAME` FROM `INFORMATION_SCHEMA`.`COLUMNS` WHERE `TABLE_SCHEMA`="'$1'" AND `TABLE_NAME`="'$2'";')
        results=("blank" "${results[@]}")
        for (( i=0; i<${#results[@]}; i++ ))
            do
                if [[ ${results[$i]} != "blank"  ]]; then
                    echo $(($i)). ${results[$i]}
                fi
        done
        read -p "Which column do you want to encrypt: " dbcolumnselect
        dbcolumn=${results[$dbcolumnselect]}
        dbcolumn=${dbcolumn//[$'\t\r\n ']}
        echo "Column Datatype:"
        for (( i=0; i<${#columnTypeArr[@]}; i++ ))
            do
                if [[ ${columnTypeArr[$i]} != "blank"  ]]; then
                    echo $(($i)). ${columnTypeArr[$i]}
                fi
        done
        read -p "What datatype is this column [$dbcolumn]: " dbcolumntype
        echo "      - column: $dbcolumn" >> acra-encryptor.yaml
        echo "        token_type: ${columnTypeArr[$dbcolumntype]}" >> acra-encryptor.yaml
        echo "        tokenized: true" >> acra-encryptor.yaml
    }

    while true
    do
        getDatabases
        while true
        do
            getTables "$dbname"
            while true
            do
                getColumns "$dbname" "$dbtable"
                read -p "Do you want to encrypt another column? (Y/n): " encryptanother
                if [[ "$encryptanother" == "N" ]] || [ "$encryptanother" == "n" ]; then
                    break
                fi
            done
            read -p "Do you want to encrypt another table? (Y/n): " encryptanothertable
            if [[ "$encryptanothertable" == "N" ]] || [ "$encryptanothertable" == "n" ]; then
                break
            fi
        done
        break
    done
    rm conn.cnf
    echo "Encryptor config generated."

# interactive for psql
elif [[ $dbserver == "P" ]] || [[ $dbserver == "p" ]]; then
    echo "Generating encryptor config interactively..."

    echo "Please log into your postgres server."
    read -p "Enter Username: " dbuser
    echo -n "Enter Password: "
    read -s dbpass
    dbpass=$(urlencode "$dbpass")
    echo 'schemas:' >> acra-encryptor.yaml

    columnTypeArr=("blank" "str" "email" "int64" "int32" "bytes")

    # create function
    getDatabases() {
        mapfile dbs < <(psql postgres://$dbuser:$dbpass@$dbhost:$dbport -t -c "SELECT datname FROM pg_database WHERE datistemplate = false;")
        clear
        echo "Listing databases..."
        dbs=("blank" "${dbs[@]}")
        unset 'dbs[${#dbs[@]}-1]'
        for (( i=0; i<${#dbs[@]}; i++ ))
            do
                if [[ ${dbs[$i]} != "blank"  ]]; then
                    dbs[$i]=${dbs[$i]:1}
                    echo $(($i)). ${dbs[$i]}
                fi
        done

        read -p "Select DB: " dbselect
        dbname=${dbs[$dbselect]}
        dbname=${dbname//[$'\t\r\n ']}

    }
    getTables() {
        clear
        echo "Listing tables..."
        mapfile tables < <(psql postgres://$dbuser:$dbpass@$dbhost:$dbport/$dbname -t -c "SELECT table_name AS Tables FROM information_schema.tables WHERE table_schema = 'public';")
        tables=("blank" "${tables[@]}")
        unset 'tables[${#tables[@]}-1]'
        for (( i=0; i<${#tables[@]}; i++ ))
            do
                if [[ ${tables[$i]} != "blank"  ]]; then
                    tables[$i]=${tables[$i]:1}
                    echo $(($i)). ${tables[$i]}
                fi
        done

        read -p "Which table do you want to encrypt: " dbtableselect
        dbtable=${tables[$dbtableselect]}
        dbtable=${dbtable//[$'\t\r\n ']}
        echo "  - table: $dbtable" >> acra-encryptor.yaml
        echo "    columns:" >> acra-encryptor.yaml
        mapfile columns < <(psql postgres://$dbuser:$dbpass@$dbhost:$dbport/$dbname -t -c "SELECT column_name FROM information_schema.columns WHERE table_schema = 'public' AND table_name = '$dbtable';")
        columns=("blank" "${columns[@]}")
        unset 'columns[${#columns[@]}-1]'
        for (( i=0; i<${#columns[@]}; i++ ))
            do
                if [[ ${columns[$i]} != "blank"  ]]; then
                    columns[$i]=${columns[$i]:1}
                    conv=${columns[$i]}
                    conv=${conv//[$'\t\r\n ']}
                    echo "      - $conv" >> acra-encryptor.yaml
                fi
        done
        echo "    encrypted:" >> acra-encryptor.yaml
    }

    getColumns() {
        clear
        echo "Listing Columns..."
        mapfile results < <(psql postgres://$dbuser:$dbpass@$dbhost:$dbport/$dbname -t -c "SELECT column_name FROM information_schema.columns WHERE table_schema = 'public' AND table_name = '$dbtable';")
        results=("blank" "${results[@]}")
        unset 'results[${#results[@]}-1]'
        for (( i=0; i<${#results[@]}; i++ ))
            do
                if [[ ${results[$i]} != "blank"  ]]; then
                    results[i]=${results[$i]:1}
                    echo $(($i)). ${results[$i]}
                fi
        done
        read -p "Which column do you want to encrypt: " dbcolumnselect
        dbcolumn=${results[$dbcolumnselect]}
        dbcolumn=${dbcolumn//[$'\t\r\n ']}
        echo "Column Datatype:"
        for (( i=0; i<${#columnTypeArr[@]}; i++ ))
            do
                if [[ ${columnTypeArr[$i]} != "blank"  ]]; then
                    echo $(($i)). ${columnTypeArr[$i]}
                fi
        done
        read -p "What datatype is this column [$dbcolumn]: " dbcolumntype
        echo "      - column: $dbcolumn" >> acra-encryptor.yaml
        echo "        token_type: ${columnTypeArr[$dbcolumntype]}" >> acra-encryptor.yaml
        echo "        tokenized: true" >> acra-encryptor.yaml
    }

    while true
    do
        getDatabases
        while true
        do
            getTables "$dbname"
            while true
            do
                getColumns "$dbname" "$dbtable"
                read -p "Do you want to encrypt another column? (Y/n): " encryptanother
                if [[ "$encryptanother" == "N" ]] || [ "$encryptanother" == "n" ]; then
                    break
                fi
            done
            read -p "Do you want to encrypt another table? (Y/n): " encryptanothertable
            if [[ "$encryptanothertable" == "N" ]] || [ "$encryptanothertable" == "n" ]; then
                break
            fi
        done
        break
    done
    echo "Encryptor config generated."
fi

cat acra-encryptor.yaml
cd
source .bashrc
echo "Run 'acra-server --config-file=/etc/acra/acra-server.yaml' to start acra"
echo "If error 'acra-server : command not found' occurs, re-run 'source .bashrc' "
