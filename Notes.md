# EC2 Instance Setup Instructions

1. Assuming you already have EC2 instance set up and SSHed into it.
2. get the public ip of the instance and point your domain's A record to it.
3. Run the setup.sql script to create necessary database tables.
    - psql -h localhost -d userstoreis -U admin -p 5432 -a -q -f /home/jobs/Desktop/resources/postgresql.sql
4. Modify the variables in setup.sh as needed.
5. Run `chmod +x setup.sh` to make the script executable.
6. Run `./setup.sh` to execute the setup script
