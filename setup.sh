#!/bin/bash

# Adiciona ao final do ~/.bashrc
echo -e "\n# Comandos adicionados pelo script de setup" >> ~/.bashrc
echo "cd teste" >> ~/.bashrc
echo "sudo bash install.sh" >> ~/.bashrc

# Executa o comando sudo bash install.sh
sudo bash install.sh
