/// A provider identity token plus the name the provider disclosed with it.
///
/// Apple shares the user's name only on their first-ever authorization and
/// never puts it in the token, so the client forwards it to Better Auth,
/// which uses it when it creates the user. The server normalises it.
class IdentityToken {
  const IdentityToken(this.token, {this.givenName, this.familyName});

  final String token;
  final String? givenName;
  final String? familyName;

  /// The Better Auth `idToken` body. `user.name` appears only when a part is
  /// non-blank, and never carries empty strings or nulls.
  Map<String, Object> toJson() =>
      idTokenJson(token, givenName: givenName, familyName: familyName);
}

Map<String, Object> idTokenJson(
  String token, {
  String? givenName,
  String? familyName,
}) {
  final first = givenName?.trim() ?? '';
  final last = familyName?.trim() ?? '';
  return {
    'token': token,
    if (first.isNotEmpty || last.isNotEmpty)
      'user': {
        'name': {
          if (first.isNotEmpty) 'firstName': first,
          if (last.isNotEmpty) 'lastName': last,
        },
      },
  };
}
