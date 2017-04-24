#!/bin/bash
# $1 domain
# $2 email


zmprov ma $2 zimbraIsDelegatedAdminAccount TRUE
zmprov ma $2 zimbraAdminConsoleUIComponents cartBlancheUI zimbraAdminConsoleUIComponents domainListView zimbraAdminConsoleUIComponents accountListView zimbraAdminConsoleUIComponents DLListView
zmprov ma $2 zimbraDomainAdminMaxMailQuota 0
zmprov grantRight domain $1 usr $2 +createAccount
zmprov grantRight domain $1 usr $2 +createAlias
zmprov grantRight domain $1 usr $2 +createCalendarResource
zmprov grantRight domain $1 usr $2 +createDistributionList
zmprov grantRight domain $1 usr $2 +deleteAlias
zmprov grantRight domain $1 usr $2 +listDomain
zmprov grantRight domain $1 usr $2 +domainAdminRights
zmprov grantRight domain $1 usr $2 +configureQuota
zmprov grantRight domain $1 usr $2 set.account.zimbraAccountStatus
zmprov grantRight domain $1 usr $2 set.account.sn
zmprov grantRight domain $1 usr $2 set.account.displayName
zmprov grantRight domain $1 usr $2 set.account.zimbraPasswordMustChange
zmprov grantRight account $2 usr $2 +deleteAccount
zmprov grantRight account $2 usr $2 +getAccountInfo
zmprov grantRight account $2 usr $2 +getAccountMembership
zmprov grantRight account $2 usr $2 +getMailboxInfo
zmprov grantRight account $2 usr $2 +listAccount
zmprov grantRight account $2 usr $2 +removeAccountAlias
zmprov grantRight account $2 usr $2 +renameAccount
zmprov grantRight account $2 usr $2 +setAccountPassword
zmprov grantRight account $2 usr $2 +viewAccountAdminUI
zmprov grantRight account $2 usr $2 +configureQuota
