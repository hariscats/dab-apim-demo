FROM mcr.microsoft.com/azure-databases/data-api-builder:1.2.11
COPY dab-config.json /App/dab-config.json
ENTRYPOINT ["dotnet", "Azure.DataApiBuilder.Service.dll", "--config", "/App/dab-config.json"]
