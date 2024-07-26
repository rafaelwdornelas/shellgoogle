#!/bin/bash

IP=185.101.94.133
PORTA=8000

# Função para verificar a existência do comando mailq
check_mailq() {
  if command -v mailq > /dev/null 2>&1; then
    echo "O comando mailq foi encontrado. A máquina pode não ter sido formatada."
    exit 1
  fi
}

# Função para obter o endereço IP externo do servidor
get_server_ip() {
  ServerIP=$(curl -s http://ipecho.net/plain)
  if [ -z "$ServerIP" ]; then
    echo "Erro ao obter o endereço IP do servidor."
    exit 1
  fi
  echo "Endereço IP do servidor: $ServerIP"
}

# Função para verificar se o IP está listado no SpamCop
check_spamcop() {
  reverse_ip=$(echo $ServerIP | awk -F "." '{print $4"."$3"."$2"."$1}')
  query="$reverse_ip.bl.spamcop.net"
  result=$(host $query)

  if [[ $result == *127.0.0.* ]]; then
    echo "O IP $ServerIP está listado no SpamCop."
    exit 1
  else
    echo "O IP $ServerIP não está listado no SpamCop."
  fi
}

# Função para obter o domínio do servidor
get_domain() {
  URL="http://$IP:$PORTA/geradominio"
  echo "URL para gerar domínio: $URL"
  sleep 6

  while true; do
    DOMINIO=$(curl -s $URL)
    if [ -z "$DOMINIO" ]; then
      echo "Erro ao obter o domínio. Tentando novamente..."
      sleep 10
      continue
    fi
    if [[ "$DOMINIO" == "Aguarde" ]]; then
      echo "Aguardando disponibilidade para gerar o domínio..."
      sleep 10
    else
      break
    fi
  done

  echo "Domínio obtido: $DOMINIO"
  DKIMSelector=$(echo $DOMINIO | awk -F[.:] '{print $1}')
}

# Função para limpar a pasta atual, exceto install.sh e .env
clean_folder() {
  find . ! -name 'install.sh' ! -name '.env' -type f -exec rm -f {} +
}

# Função para baixar arquivos necessários
download_files() {
  local files=(
    "https://raw.githubusercontent.com/rafaelwdornelas/goenvios/main/envio3.raf envio.zip"
    "https://raw.githubusercontent.com/rafaelwdornelas/goenvios/main/dns.txt dns.txt"
  )

  for file in "${files[@]}"; do
    local url=$(echo $file | awk '{print $1}')
    local destino=$(echo $file | awk '{print $2}')
    echo "Baixando $url ..."
    curl -o "$destino" "$url"
    if [ $? -eq 0 ]; then
      echo "Download concluído com sucesso. O arquivo foi salvo como $destino."
    else
      echo "Ocorreu um erro durante o download de $url."
      exit 1
    fi
  done
}

# Função para instalar pacotes
install_packages() {
  sudo DEBIAN_FRONTEND=noninteractive apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y software-properties-common dnsutils screen unzip bind9 bind9utils bind9-doc apache2 mutt mailutils

  # Definir o frontend do debconf para não interativo
  export DEBIAN_FRONTEND=noninteractive

  debconf-set-selections <<< "postfix postfix/mailname string '$DOMINIO'"
  debconf-set-selections <<< "postfix postfix/main_mailer_type string 'Internet Site'"
  debconf-set-selections <<< "postfix postfix/destinations string '$DOMINIO, localhost'"
  # Instalação não interativa do Postfix
  sudo DEBIAN_FRONTEND=noninteractive apt-get install --assume-yes postfix

  # Verifica se o Postfix foi instalado corretamente
  if ! command -v postconf &> /dev/null; then
    echo "Erro: Postfix não foi instalado corretamente."
    exit 1
  fi
}

# Função para configurar hostname e hosts
configure_hostname() {
  echo "$DOMINIO" | sudo tee /etc/hostname
  echo "127.0.1.2  $DOMINIO" | sudo tee -a /etc/hosts
  echo "$DOMINIO" | sudo tee /etc/mailname
  sudo hostname "$DOMINIO"
  sudo hostnamectl set-hostname "$DOMINIO"
}

# Função para configurar DNS
configure_dns() {
  # Remove quaisquer configurações de DNS existentes no arquivo resolv.conf
  sudo sed -i '/^nameserver/d' /etc/resolv.conf
  echo "nameserver 8.8.8.8" | sudo tee -a /etc/resolv.conf
  echo "nameserver 8.8.4.4" | sudo tee -a /etc/resolv.conf

  # Pega o dns.txt e adiciona 40 servidores DNS de forma randômica
  shuf -n 40 dns.txt | while read -r line; do
    echo "nameserver $line" | sudo tee -a /etc/resolv.conf
  done

  sudo /etc/init.d/networking restart
}

# Função para configurar SSL
configure_ssl() {
  sudo mkdir -p /etc/configs/ssl/new/
  openssl genrsa -des3 --passout pass:789456 -out certificado.key 2048
  openssl req -new -passin pass:789456 -key certificado.key -subj "/C=BR/ST=Sao Paulo/L=Sao Paulo/O=Nodemailer/OU=IT Department/CN=$DOMINIO" -out certificado.csr
  openssl x509 -req --passin pass:789456 -days 365 -in certificado.csr -signkey certificado.key -out certificado.cer
  openssl rsa --passin pass:789456 -in certificado.key -out certificado.key.nopass
  mv -f certificado.key.nopass certificado.key
  openssl req -new -x509 -extensions v3_ca -passout pass:789456 -subj "/C=BR/ST=Sao Paulo/L=Sao Paulo/O=Nodemailer/OU=IT Department/CN=$DOMINIO" -keyout cakey.pem -out cacert.pem -days 3650
  sudo chmod 600 certificado.key cakey.pem
  sudo mv certificado.key certificado.cer cakey.pem cacert.pem /etc/configs/ssl/new/
}

# Função para configurar o Postfix
configure_postfix() {
  echo "postfix postfix/main_mailer_type string 'internet sites'" | sudo debconf-set-selections
  echo "postfix postfix/mailname string $DOMINIO" | sudo debconf-set-selections

  # Configurações principais
  sudo postconf -e "myhostname=$DOMINIO"
  sudo postconf -e "smtpd_banner=$DOMINIO ESMTP Amazon SES"
  sudo postconf -e "biff=no"
  sudo postconf -e "append_dot_mydomain=no"
  sudo postconf -e "readme_directory=no"

  # Configurações TLS
  sudo postconf -e "smtpd_use_tls=yes"
  sudo postconf -e "smtpd_tls_cert_file=/etc/configs/ssl/new/certificado.cer"
  sudo postconf -e "smtpd_tls_key_file=/etc/configs/ssl/new/certificado.key"
  sudo postconf -e "smtpd_tls_CAfile=/etc/configs/ssl/new/cacert.pem"
  sudo postconf -e "smtpd_tls_security_level=may"
  sudo postconf -e "smtp_tls_security_level=may"
  sudo postconf -e "smtpd_tls_auth_only=yes"
  sudo postconf -e "smtpd_tls_session_cache_database=btree:/var/lib/postfix/smtpd_scache"
  sudo postconf -e "smtp_tls_session_cache_database=btree:/var/lib/postfix/smtp_scache"

  # Configurações de rede
  sudo postconf -e "mydestination=$DOMINIO, localhost"
  sudo postconf -e "mynetworks=127.0.0.0/8 [::ffff:127.0.0.0]/104 [::1]/128 172.0.0.0/8 192.168.0.0/16 10.0.0.0/8"

  # Configurações de alias
  sudo postconf -e "default_destination_rate_delay=2m"
  sudo postconf -e "default_destination_concurrency_failed_cohort_limit=10"
}

# Função para baixar e atualizar o arquivo .env
update_env() {
  URL="http://$IP:$PORTA/env"
  curl -s $URL > .env
}

# Função para criar chaves DKIM
create_dkim_keys() {
  openssl genrsa -out dkim_private.pem 2048
  openssl rsa -in dkim_private.pem -pubout -outform der 2>/dev/null | openssl base64 -A > dkim_public.txt
}

# Função principal
main() {
  clean_folder
  check_mailq
  get_server_ip
  check_spamcop
  get_domain
  download_files
  configure_hostname
  install_packages
  configure_dns
  configure_ssl
  configure_postfix
  create_dkim_keys
  update_env

  sudo service postfix restart

  unzip envio.zip -d ./ && chmod 777 -R ./goenvio
  ./goenvio DNS

  echo "INSTALAÇÃO CONCLUÍDA"
  ./goenvio
}

main "$@"
